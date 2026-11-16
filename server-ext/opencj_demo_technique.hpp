#ifndef OPENCJ_DEMO_TECHNIQUE_HPP
#define OPENCJ_DEMO_TECHNIQUE_HPP
#include <cmath>

// Playback interpretation only. The original recording and game physics never
// receive these transformed inputs. Samples are 50 ms apart.
struct CJ_DemoInput {
    int forward, right;
    bool ground, cut, excluded, shot;
};
struct CJ_DemoTechnique {
    int forward, right;
    float yawOffset;
    bool changed, fallback;
};
inline float CJ_DemoInputAngle(int forward,int right) {
    return std::atan2(float(-right),float(forward))*180.0f/3.14159265358979323846f;
}
// Cache only the classification for one airborne section.
// This avoids rescanning the same jump for every sample during an FPS rebuild.
struct CJ_DemoSection {
    int begin,end,anchorF,anchorR,style,takeoffEnd;
};
template<class Read>
CJ_DemoSection CJ_AnalyzeDemoTechnique(int count,int index,Read read)
{
    CJ_DemoSection section={};section.begin=index;section.end=index+1;
    const CJ_DemoInput input=read(index);
    if(input.ground || input.cut)return section;
    int begin=index,end=index+1;
    while(begin>0 && index-begin<512) {
        const CJ_DemoInput previous=read(begin-1),current=read(begin);
        if(previous.ground || current.cut)break;
        --begin;
    }
    if(begin>0 && index-begin==512)return section;
    while(end<count && end-begin<512) {
        const CJ_DemoInput next=read(end);
        if(next.ground || next.cut)break;
        ++end;
    }
    if(end<count && end-begin==512)return section;
    section.begin=begin;section.end=end;
    int anchorF=0,anchorR=0,lastF=0,lastR=0;
    bool haveLast=false,full=false,half=false,invert=false,mixedForward=false;
    int singleRight=0,singleSwitches=0,firstSingleRight=0;
    for(int first=begin;first<end;) {
        CJ_DemoInput phase=read(first);
        int last=first+1;
        while(last<end) {
            const CJ_DemoInput next=read(last);
            if(next.forward!=phase.forward || next.right!=phase.right || next.excluded!=phase.excluded)break;
            ++last;
        }
        const bool stable=last-first>=3 || (first==begin && phase.forward && phase.right);
        if(stable && !phase.excluded && phase.right) {
            if(phase.forward) {
                singleRight=0;singleSwitches=0;
                if(!anchorF){anchorF=phase.forward;anchorR=phase.right;section.takeoffEnd=last;}
                else if(phase.forward!=anchorF)mixedForward=true;
                else if(phase.right==-anchorR)full=true;
                if(haveLast && !lastF && lastR==-phase.right && phase.forward==anchorF && phase.right==anchorR)half=true;
                lastF=phase.forward;lastR=phase.right;haveLast=true;
            } else {
                // A repeated A/D/A pattern establishes Invert, rather than
                // interpreting one released diagonal as another technique.
                if(!firstSingleRight)firstSingleRight=phase.right;
                if(singleRight && singleRight==-phase.right)++singleSwitches;
                singleRight=phase.right;
                if(singleSwitches>=2)invert=true;
                if(anchorF && phase.right==-anchorR) {
                    lastF=0;lastR=phase.right;haveLast=true;
                }
            }
        }
        first=last;
    }
    // Anchor the viewing pattern to the original takeoff. Re-anchoring to an
    // opposite-side RPG leaves a two-phase WA -> WD jump entirely unconverted.
    // Shot aiming is handled by the camera, independently of converted keys.
    if(!anchorF && invert){anchorF=1;anchorR=firstSingleRight;section.takeoffEnd=begin;}
    section.anchorF=anchorF;section.anchorR=anchorR;
    if(anchorF && !mixedForward && (full || half || invert))section.style=(full?1:0)|(half?2:0)|(invert?4:0);
    return section;
}
inline CJ_DemoTechnique CJ_ApplyDemoTechnique(int index,int mode,const CJ_DemoInput &input,const CJ_DemoSection &section)
{
    CJ_DemoTechnique result={input.forward,input.right,0,false,false};
    if(!mode || input.ground)return result;
    if(input.cut || input.excluded || !section.style){result.fallback=true;return result;}
    if(index<section.begin || index>=section.end)return result;
    // Preserve the original diagonal takeoff; the opposing phase converts
    // from its first recorded sample, including bounce and RPG samples.
    if((mode==2 || mode==3) && index<section.takeoffEnd && input.forward && input.right)return result;
    if(mode==1 && !input.forward && input.right && (input.right==-section.anchorR || (section.style&4)))
        result.forward=section.anchorF;
    else if(mode==2 && input.forward==section.anchorF && input.right==-section.anchorR)
        result.forward=0;
    else if(mode==2 && (section.style&4) && !input.forward && input.right==section.anchorR)
        result.forward=section.anchorF;
    else if(mode==3 && input.right && input.forward==section.anchorF)
        result.forward=0;
    result.changed=result.forward!=input.forward;
    if(result.changed)
        result.yawOffset=std::remainder(CJ_DemoInputAngle(input.forward,input.right)-
            CJ_DemoInputAngle(result.forward,result.right),360.0f);
    return result;
}
template<class Read>
CJ_DemoTechnique CJ_InterpretDemoTechnique(int count,int index,int mode,Read read)
{
    return CJ_ApplyDemoTechnique(index,mode,read(index),CJ_AnalyzeDemoTechnique(count,index,read));
}
struct CJ_DemoCameraSample {
    float yaw,offset;
    bool cut,locked,shot;
};
// Ease only camera changes introduced by conversion. Recorded RPG aim, ground
// frames and load cuts remain exact. Position, velocity and FPS never enter here.
template<class Sample>
float CJ_SmoothDemoYaw(int count,int index,Sample sample)
{
    const CJ_DemoCameraSample center=sample(index);
    if(center.locked || center.cut || center.shot)return center.yaw;
    const float target=center.yaw+center.offset;
    float sum=3*center.offset,weight=3,protection=1,shotScale=1;
    bool transition=false;
    for(int direction=-1;direction<=1;direction+=2) {
        CJ_DemoCameraSample previous=center;
        for(int distance=1;distance<=3;++distance) {
            int n=index+direction*distance;
            if(n<0 || n>=count)break;
            const CJ_DemoCameraSample next=sample(n);
            if(direction>0?next.cut:previous.cut)break;
            // A shot uses a short 100 ms approach and departure. Keep it out
            // of the ordinary smoothing kernel, which otherwise adds a second
            // slow dip on top of the aiming turn.
            if(next.shot)shotScale=std::fmin(shotScale,distance/2.0f);
            if(next.locked)protection=std::fmin(protection,distance/3.0f);
            if(std::fabs(std::remainder(next.offset-center.offset,360.0f))>.01f)transition=true;
            if(distance<=2) {
                const float w=3-distance;
                sum+=w*(center.offset+std::remainder(next.offset-center.offset,360.0f));
                weight+=w;
            }
            previous=next;
        }
    }
    if(!transition)return center.yaw+shotScale*(target-center.yaw);
    return center.yaw+shotScale*protection*sum/weight;
}

#endif
