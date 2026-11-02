"""Convert fixed preprocessing + Ridge coefficients to an on-device Core ML linear network."""
import argparse, json, shutil
from pathlib import Path
import numpy as np
import coremltools as ct
from coremltools.models import datatypes
from coremltools.models.neural_network import NeuralNetworkBuilder

def export(artifacts, destination):
    model=json.loads((artifacts/'linear_model.json').read_text())
    manifest=json.loads((artifacts/'forecast_manifest.json').read_text())
    builder=NeuralNetworkBuilder([('features',datatypes.Array(38))],[('forecast',datatypes.Array(2))],disable_rank5_shape_mapping=True)
    builder.add_inner_product(name='ridge',W=np.array(model['weights']),b=np.array(model['bias']),
        input_channels=38,output_channels=2,has_bias=True,input_name='features',output_name='forecast')
    ml=ct.models.MLModel(builder.spec, compute_units=ct.ComputeUnit.CPU_ONLY)
    ml.short_description='Joe experimental 30/60 minute glucose forecasts. No dosing or pump control.'
    ml.user_defined_metadata['featureSchema']=manifest['schema'];ml.user_defined_metadata['modelVersion']=manifest['modelVersion']
    # Verify numerical parity before installing any resources.
    for row in json.loads((artifacts/'prediction_fixtures.json').read_text()):
        actual=ml.predict({'features':np.array(row['input'])})['forecast'].reshape(-1)
        np.testing.assert_allclose(actual,row['expected'],rtol=1e-4,atol=.02)
    destination.mkdir(parents=True,exist_ok=True)
    ml.save(str(destination/'GlucoseForecaster.mlmodel'))
    shutil.copy2(artifacts/'forecast_manifest.json',destination/'forecast_manifest.json')
    print('Exported model; rerun scripts/generate_project.py, then perform iPhone fixture verification.')
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--artifacts',default='artifacts');p.add_argument('--destination',default='../../ios/JoeMobile/Resources');a=p.parse_args()
    export(Path(a.artifacts),Path(a.destination))
