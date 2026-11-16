"""Provider input tests: reject broken/overlapping datasets and preserve CIDR ends."""
import csv,gzip,importlib.util,ipaddress,tempfile,unittest
from pathlib import Path
spec=importlib.util.spec_from_file_location("updater",Path(__file__).with_name("update.py"))
updater=importlib.util.module_from_spec(spec);spec.loader.exec_module(updater)

class ProviderTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name)
    def tearDown(self):self.temp.cleanup()
    def data(self,rows):
        path=self.root/'input.csv.gz'
        with gzip.open(path,'wt',newline='') as stream:csv.writer(stream).writerows(rows)
        return path
    def prepare(self,rows,minimum=1):
        return updater.prepare(self.data(rows),self.root/'cache.sqlite',minimum=minimum)
    def test_endpoints_ipv6_and_gaps(self):
        db,meta=self.prepare([['8.8.8.0','8.8.8.7','US'],['8.8.8.16','8.8.8.31','GB'],['2001:db8::','2001:db8::ffff','NL']])
        self.addCleanup(db.close)
        self.assertEqual(meta['ranges'],2);self.assertEqual(meta['addresses'],24)
        self.assertEqual(list(db.execute('SELECT * FROM ranges ORDER BY start'))[0][:2],(int(ipaddress.ip_address('8.8.8.0')),int(ipaddress.ip_address('8.8.8.7'))))
    def test_overlap_rejected(self):
        with self.assertRaises(ValueError):self.prepare([['8.8.8.0','8.8.8.20','US'],['8.8.8.16','8.8.8.31','GB']])
    def test_empty_rejected(self):
        with self.assertRaises(ValueError):self.prepare([])
    def test_malformed_country_rejected(self):
        with self.assertRaises(ValueError):self.prepare([['8.8.8.0','8.8.8.7','U;']])
    def test_truncated_gzip_rejected(self):
        path=self.data([['8.8.8.0','8.8.8.7','US']]);path.write_bytes(path.read_bytes()[:-5])
        with self.assertRaises(EOFError):updater.prepare(path,self.root/'cache.sqlite',minimum=1)
    def test_geolite_quoted_names_and_unlocated_blocks(self):
        (self.root/'GeoLite2-Country-Locations-en.csv').write_text('geoname_id,locale_code,continent_code,continent_name,country_iso_code,country_name,is_in_european_union\n1,en,NA,North America,BQ,"Bonaire, Sint Eustatius and Saba",0\n')
        (self.root/'GeoLite2-Country-Blocks-IPv4.csv').write_text('network,geoname_id,registered_country_geoname_id\n8.8.8.0/29,1,1\n8.8.8.16/28,,1\n')
        db,meta=updater.prepare(self.root,self.root/'cache.sqlite',geolite=True,minimum=1);self.addCleanup(db.close)
        rows=list(db.execute('SELECT * FROM ranges ORDER BY start'))
        self.assertEqual(rows[0][2],'BQ');self.assertEqual(rows[1][2],'XX')
        self.assertEqual(rows[0][1]-rows[0][0],7)
if __name__=='__main__':unittest.main()
