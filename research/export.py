# Exports RVM to the Core ML package in Resources/. Float16 tensors throughout, so the GPU reads
# and writes the model's IOSurface buffers directly and Core ML has no pixel conversion to do.
import sys,torch,numpy as np,coremltools as ct
sys.path.insert(0,'third_party/RVM')
from model import MattingNetwork
w,h,ratio=1280,720,0.375
out=sys.argv[1] if len(sys.argv)>1 else 'Resources/rvm.mlpackage'
m=MattingNetwork('mobilenetv3').eval(); m.load_state_dict(torch.load('models/rvm_mobilenetv3.pth',map_location='cpu',weights_only=True))
class W(torch.nn.Module):
    def __init__(s,m): super().__init__(); s.m=m
    def forward(s,src,r1,r2,r3,r4):
        return s.m(src,r1,r2,r3,r4,downsample_ratio=ratio)
src=torch.rand(1,3,h,w)
with torch.no_grad():
    # learn recurrent shapes by running once from empty state
    f,p,*rec=m(src,downsample_ratio=ratio)
    tr=torch.jit.trace(W(m),(src,*rec),strict=False)
print([tuple(r.shape) for r in rec])
F=np.float16
inputs=[ct.TensorType(name='src',shape=(1,3,h,w),dtype=F)]+[ct.TensorType(name=f'r{i+1}i',shape=r.shape,dtype=F) for i,r in enumerate(rec)]
outputs=[ct.TensorType(name='fgr',dtype=F),ct.TensorType(name='pha',dtype=F)]+[ct.TensorType(name=f'r{i+1}o',dtype=F) for i in range(4)]
ml=ct.convert(tr,inputs=inputs,outputs=outputs,convert_to='mlprogram',compute_precision=ct.precision.FLOAT16,minimum_deployment_target=ct.target.macOS14)
ml.save(out); print('saved',out)
