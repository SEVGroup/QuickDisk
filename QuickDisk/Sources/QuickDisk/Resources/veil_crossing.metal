#include <metal_stdlib>
using namespace metal;
struct V{float4 p [[position]];};
vertex V vert(uint i [[vertex_id]]){float2 p=float2((i<<1)&2,i&2);return {float4(p*2-1,0,1)};}
float2 rot(float2 p,float a){return float2(cos(a)*p.x-sin(a)*p.y,sin(a)*p.x+cos(a)*p.y);}
float3 palette(float x){float y=.5+.5*cos(6.28318*x);return float3(y);}
fragment float4 frag(V v [[stage_in]],constant float3 &u [[buffer(0)]]){
 float t=u.z,wt=t+72.;float2 uv=(v.p.xy*2-u.xy)/u.y;float2 p=rot(uv,wt*.018);float3 c=0.;
 float aperture=.12+.08*sin(wt*.09);float env=exp(-p.x*p.x*1.4);
 for(int i=0;i<11;i++){float f=float(i)-5.;float x=f*.145;float bend=.095*sin(p.y*(2.1+abs(f)*.08)-wt*.19+f*.47)+.032*sin(p.y*5.+wt*.11-f);float d=abs(p.x-x-bend);float weight=.0045/(d+.008);float hue=.56+f*.035+wt*.004;
  float gate=1.-.72*exp(-pow((p.y-aperture*sin(f*.5+wt*.075))/.25,2.));c+=palette(hue+p.y*.05)*weight*gate*env;}
 float cross=abs(p.y-.24*sin(p.x*2.6-wt*.12)-.08*sin(wt*.07));c+=palette(.08+p.x*.12-wt*.006)*(.003/(cross+.012))*exp(-p.x*p.x*.8);
 float far=abs(p.y+.20*sin(p.x*2.1+wt*.1)+.06*sin(wt*.06));c+=palette(.61+p.x*.1+wt*.004)*(.0022/(far+.014))*exp(-p.x*p.x*.7);
 float fade=1.;
 float grain=fract(sin(dot(v.p.xy,float2(12.9898,78.233)))*43758.5453);c=1-exp(-max(c,0.)*1.32);c*=max(0.,1.-.14*dot(uv,uv));c=pow(max(c,0.),float3(.88));c=(c+(grain-.5)*.012)*fade;return float4(c,1.);
}
