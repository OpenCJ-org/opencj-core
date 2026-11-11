// Real MySQL integration tests for the production pool; disposable schema only.
#include "../../server-ext/mysql_async_pool.hpp"
#include <iostream>
#include <fstream>
#include <string>
#include <vector>
#include <stdexcept>
#include <chrono>
#include <unistd.h>
#include <dirent.h>
using namespace std;
static int checks=0;
static long long ms(){return chrono::duration_cast<chrono::milliseconds>(chrono::steady_clock::now().time_since_epoch()).count();}
static void check(bool value,const char *label) {
    checks++;cout<<"SQLPOOL CHECK "<<value<<": "<<label<<endl;
    if(!value)throw runtime_error(label);
}
static int submit(const string &q,int policy=SQL_READ,const string &key="",const string &scope="",int deadline=10000) {
    return sqlPoolSubmit(q.c_str(),true,policy,key.c_str(),scope.c_str(),deadline);
}
struct Reply { SqlCompletion c; vector<vector<string>> rows; };
static Reply take(int id) {
    check(id>0,"request admitted");
    long long deadline=ms()+15000;SqlCompletion c;MYSQL_RES *result=NULL;
    while(!sqlPoolStatus(id,&c) && ms()<deadline)usleep(1000);
    if(!sqlPoolTake(id,&result,&c))throw runtime_error("completion deadline");
    Reply reply;reply.c=c;
    if(result) {
        MYSQL_ROW row;
        while((row=mysql_fetch_row(result))) {
            vector<string> fields;
            for(unsigned i=0;i<mysql_num_fields(result);i++)fields.push_back(row[i]?row[i]:"NULL");
            reply.rows.push_back(fields);
        }
        mysql_free_result(result);
    }
    return reply;
}
static Reply run(const string &q,int policy=SQL_READ,const string &key="") {return take(submit(q,policy,key));}
static int scalar(const string &q) {auto r=run(q);if(r.c.outcome!=SQL_OK || r.rows.empty())throw runtime_error("scalar failed");return stoi(r.rows[0][0]);}
static void drain(const vector<int> &ids) {for(int id:ids)if(id>0)take(id);}
static void waitRunning(int count) {
    long long end=ms()+1000;
    while(sqlPoolStats().running<count && ms()<end)usleep(1000);
    check(sqlPoolStats().running>=count,"blocking fixture occupies intended workers");
}
static int threadCount() {
    DIR *d=opendir("/proc/self/task");if(!d)throw runtime_error("thread inventory");
    int n=0;dirent *entry;while((entry=readdir(d)))if(entry->d_name[0]!='.')n++;
    closedir(d);return n;
}
int main(int argc,char **argv) {
    try {
        if(argc!=2)throw runtime_error("config path required");
        ifstream config(argv[1]);string host,user,password,database,port;
        getline(config,host);getline(config,user);getline(config,password);getline(config,database);getline(config,port);
        if(database.find("opencj_verify_192_")!=0)throw runtime_error("unsafe test schema");
        check(sqlPoolInit(host.c_str(),user.c_str(),password.c_str(),database.c_str(),stoi(port),4),"four permanent workers connected");
        check(sqlPoolStats().workers==4,"pool size remains four");
        int threads=threadCount();check(threads==5,"exactly four native worker threads");
        run("CREATE TABLE adapter_probe(seq INT AUTO_INCREMENT PRIMARY KEY,value INT) ENGINE=InnoDB",SQL_PROGRESS);
        check(run("SELECT value FROM adapter_probe").rows.empty(),"empty read is successful");
        check(run("SELECT * FROM missing_adapter_table").c.outcome==SQL_ERROR,"SQL error remains explicit");
        // Priority cannot overtake earlier work for the same run.
        int first=submit("INSERT INTO adapter_probe(value) SELECT 10 FROM (SELECT SLEEP(0.15)) a",SQL_BACKGROUND,"run:order");
        int second=submit("UPDATE adapter_probe SET value=11 WHERE value=10",SQL_PROGRESS,"run:order");
        take(second);take(first);
        check(scalar("SELECT COUNT(*) FROM adapter_probe WHERE value=11")==1,"per-run order survives priority differences");

        vector<int> blockers;
        for(int i=0;i<3;i++)blockers.push_back(submit("SELECT SLEEP(0.6),1",SQL_MENU,"","block:"+to_string(i)));
        waitRunning(3);
        vector<int> storm;
        for(int i=0;i<100;i++)storm.push_back(submit("SELECT SLEEP(0.02),1",SQL_MENU,"","storm:"+to_string(i)));
        auto saturation=sqlPoolStats();
        check(saturation.outstanding<=64 && saturation.rejected>0,"menu admission is bounded at 64 outstanding jobs");
        long long begin=ms();
        auto progress=run("INSERT INTO adapter_probe(value) VALUES(20)",SQL_PROGRESS,"run:priority");
        long long latency=ms()-begin;
        check(progress.c.outcome==SQL_OK && latency<300,"progress completes while all three menu workers are busy");
        cout<<"SQLPOOL METRIC progress_during_menu_burst_ms="<<latency<<endl;
        sqlPoolCancel("storm:",true,false);
        for(int id:storm)if(id>0)check(take(id).c.outcome==SQL_CANCELLED,"queued obsolete menu returns cancellation");
        drain(blockers);
        check(sqlPoolStats().outstanding==0,"all results collected after storm");

        // Completed jobs occupy slots too. No consumer means bounded admission.
        vector<int> buffered;
        for(int i=0;i<700;i++) {
            int id=submit("SELECT 1",SQL_READ);
            if(id>0)buffered.push_back(id);
        }
        check(sqlPoolStats().outstanding<=384 && buffered.size()<=384,"uncollected results count against non-progress capacity");
        check(run("INSERT INTO adapter_probe(value) VALUES(21)",SQL_PROGRESS,"run:reserved").c.outcome==SQL_OK,"reserved progress capacity survives a stalled consumer");
        drain(buffered);

        // Query bytes are a second independent admission bound.
        string large="DO SLEEP(0.02) /*"+string(10000,'x')+"*/";
        vector<int> largeJobs;
        for(int i=0;i<400;i++) {
            int id=submit(large,SQL_BACKGROUND,"bulk");
            if(id>0)largeJobs.push_back(id);
        }
        auto bytes=sqlPoolStats();
        check(bytes.queryBytes<=1536*1024 && largeJobs.size()<384,"byte limit rejects before job-count limit");
        check(run("INSERT INTO adapter_probe(value) VALUES(22)",SQL_PROGRESS,"run:bytes").c.outcome==SQL_OK,"progress byte reserve remains available");
        drain(largeJobs);

        int slow=submit("DO SLEEP(0.2)",SQL_PROGRESS,"run:expire");
        int expired=submit("INSERT INTO adapter_probe(value) VALUES(99)",SQL_PROGRESS,"run:expire","",20);
        take(slow);
        check(take(expired).c.outcome==SQL_EXPIRED && scalar("SELECT COUNT(*) FROM adapter_probe WHERE value=99")==0,"expired queued write is rejected without execution");

        int persistence=submit("INSERT INTO adapter_probe(value) SELECT 30 FROM (SELECT SLEEP(0.2)) a",SQL_PROGRESS,"run:map");
        int oldMenu=submit("SELECT SLEEP(0.4),1",SQL_MENU,"","p:1:board");
        sqlPoolNewMap();
        check(take(persistence).c.outcome==SQL_OK,"accepted write survives map lifecycle cancellation");
        usleep(450000);
        SqlCompletion unused;
        check(!sqlPoolStatus(oldMenu,&unused),"old-map menu result discarded");
        check(sqlPoolStats().outstanding==0 && sqlPoolStats().workers==4,"map transition retains workers without leaking completed tasks");

        int disconnected=submit("SELECT SLEEP(0.2),1",SQL_MENU,"","p:8:board");
        sqlPoolCancel("p:8:",true,true);usleep(250000);
        check(sqlPoolStats().outstanding==0,"disconnect cancels scoped reads without leaking jobs");

        vector<int> writes;
        for(int i=0;i<100;i++)writes.push_back(submit("DO SLEEP(0.01)",SQL_PROGRESS,"r:"+to_string(i)));
        int background=submit("INSERT INTO adapter_probe(value) VALUES(40)",SQL_BACKGROUND,"background");
        auto fair=take(background);
        check(fair.c.outcome==SQL_OK && fair.c.waitMs<1000,"background work is not starved by continuous progress work");
        drain(writes);

        auto timed=run("SELECT SLEEP(10),1",SQL_READ);
        cout<<"SQLPOOL METRIC slow_outcome="<<timed.c.outcome<<" error="<<timed.c.error<<" execution_ms="<<timed.c.executionMs<<endl;
        check(timed.c.executionMs<8000 && (timed.c.outcome!=SQL_OK || (!timed.rows.empty() && timed.rows[0][0]=="1")),"slow read is interrupted within the configured budget");
        check(scalar("SELECT 1")==1,"pool recovers after slow read");
        // A long writing CALL may have committed before losing its reply.
        run("CREATE PROCEDURE adapter_uncertain() BEGIN INSERT INTO adapter_probe(value) VALUES(50); DO SLEEP(10); END",SQL_PROGRESS);
        auto uncertain=run("CALL adapter_uncertain()",SQL_PROGRESS,"run:uncertain");
        check(uncertain.c.outcome==SQL_UNKNOWN && uncertain.c.executionMs<8000,"lost write reply is explicitly uncertain");
        check(scalar("SELECT COUNT(*) FROM adapter_probe WHERE value=50")<=1,"uncertain write is never automatically replayed");
        auto final=sqlPoolStats();
        check(final.outstanding==0 && final.queryBytes==0,"all query allocations and completions released");
        cout<<"SQLPOOL METRIC accepted="<<final.accepted<<" rejected="<<final.rejected
            <<" peak_jobs="<<final.peakJobs<<" peak_query_bytes="<<final.peakBytes
            <<" max_wait_ms="<<final.maxWaitMs<<" max_execution_ms="<<final.maxExecutionMs<<endl;
        check(threadCount()==threads,"query volume does not create additional worker threads");
        sqlPoolShutdown();
        cout<<"SQLPOOL COMPLETE checks="<<checks<<endl;
        return 0;
    } catch(const exception &error) {
        cout<<"SQLPOOL FAILURE "<<error.what()<<endl;
        sqlPoolShutdown();return 1;
    }
}
