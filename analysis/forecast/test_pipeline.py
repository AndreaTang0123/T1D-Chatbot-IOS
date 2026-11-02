import json, math, tempfile, unittest
from pathlib import Path
from features import feature_row, SCHEMA, INPUT_NAMES
from build_dataset import build

def synthetic_export(count=600):
    from datetime import datetime,timezone
    def iso(t): return datetime.fromtimestamp(t,timezone.utc).isoformat()
    start=1800000000
    return {'glucose':[{'id':str(i),'timestamp':iso(start+i*300),'glucose':120+20*math.sin(i/20),'receivedAt':iso(start+i*300)} for i in range(count)],
            'treatments':[],'contexts':[]}

class PipelineTests(unittest.TestCase):
    def test_dataset_targets_and_causal_history(self):
        data=build(synthetic_export(100))
        self.assertEqual(data['schema'],SCHEMA);self.assertEqual(len(data['rows']),82)
        first=data['rows'][0]; self.assertEqual(first['sourceTimestamp'],1800001800)
        self.assertTrue(all(t>first['sourceTimestamp'] for t in first['targetTimes']))
        self.assertEqual(len(first['input']),38)
    def test_future_context_and_treatment_do_not_leak(self):
        g=[{'t':1800000000+(i-6)*300,'g':100+i} for i in range(7)];t=g[-1]['t']
        baseline=feature_row(g,[],[],t)
        actual=feature_row(g,[{'t':t+1,'insulin':10}],[{'t':t+1,'steps':999}],t)
        self.assertEqual(baseline,actual)
    def test_missing_gap_blocks_features(self):
        g=[{'t':1800000000+(i-6)*300,'g':100+i} for i in range(7) if i!=3]
        self.assertIsNone(feature_row(g,[],[],1800000000))
    def test_sparse_future_not_labeled_no_low(self):
        export=synthetic_export(100);del export['glucose'][20]
        data=build(export)
        affected=[r for r in data['rows'] if r['sourceTimestamp']==1800000000+10*300]
        self.assertEqual(len(affected),1);self.assertIsNone(affected[0]['lowWithin60'])
    def test_chronological_training_and_export(self):
        from train import train
        data=build(synthetic_export())
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory);train(data,path)
            report=json.loads((path/'report.json').read_text());ranges=report['splitSourceTimeRanges']
            self.assertLess(ranges[0][1]+3750,ranges[1][0]);self.assertLess(ranges[1][1]+3750,ranges[2][0])
            self.assertEqual(set(report['experiments']),set('ABCD'))
            self.assertEqual(json.loads((path/'forecast_manifest.json').read_text())['inputNames'],INPUT_NAMES)
    def test_coreml_parity_export(self):
        # Synthetic pipeline integration only; output is ephemeral and never bundled with the app.
        from train import train
        from export_coreml import export
        data=build(synthetic_export())
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory);train(data,path/'artifacts');export(path/'artifacts',path/'resources')
            self.assertTrue((path/'resources/GlucoseForecaster.mlmodel').exists())
if __name__=='__main__':unittest.main()
