import sys,torch,coremltools as ct
sys.path.insert(0,'third_party/RVM')
from model import MattingNetwork
w,h,ratio,name=int(sys.argv[1]),int(sys.argv[2]),float(sys.argv[3]),sys.argv[4]
m=MattingNetwork('mobilenetv3').eval(); m.load_state_dict(torch.load('models/rvm_mobilenetv3.pth',map_location='cpu',weights_only=True))
class W(torch.nn.Module):
    def __init__(s,m): super().__init__(); s.m=m
    def forward(s,src,r1,r2,r3,r4):
        f,p,a,b,c,d=s.m(src,r1,r2,r3,r4,downsample_ratio=ratio)
        return f*255,p*255,a,b,c,d
src=torch.rand(1,3,h,w)
with torch.no_grad():
    # learn recurrent shapes by running once from empty state
    f,p,*rec=m(src,downsample_ratio=ratio)
print([tuple(r.shape) for r in rec])
with torch.no_grad(): tr=torch.jit.trace(W(m),(src,*rec),strict=False)
inputs=[ct.ImageType(name='src',shape=(1,3,h,w),scale=1/255,color_layout=ct.colorlayout.RGB)]+[ct.TensorType(name=f'r{i+1}i',shape=r.shape) for i,r in enumerate(rec)]
outputs=[ct.ImageType(name='fgr',color_layout=ct.colorlayout.RGB),ct.ImageType(name='pha',color_layout=ct.colorlayout.GRAYSCALE)]+[ct.TensorType(name=f'r{i+1}o') for i in range(4)]
ml=ct.convert(tr,inputs=inputs,outputs=outputs,convert_to='mlprogram',compute_precision=ct.precision.FLOAT16,minimum_deployment_target=ct.target.macOS14)
ml.save(f'models/{name}.mlpackage'); print('saved',name)
