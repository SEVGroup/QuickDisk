#include <metal_stdlib>
using namespace metal;
struct V{float4 p [[position]];};
vertex V vert(uint i [[vertex_id]]){float2 p=float2((i<<1)&2,i&2);return {float4(p*2-1,0,1)};}
float2 rot(float2 p,float a){return float2(cos(a)*p.x-sin(a)*p.y,sin(a)*p.x+cos(a)*p.y);}
float3 palette(float x){return .5+.5*cos(6.28318*(x+float3(0,.33,.67)));}
fragment float4 frag(V v [[stage_in]],constant float3 &u [[buffer(0)]]){
 float t=u.z,wt=t+72.;float2 uv=(v.p.xy*2-u.xy)/u.y;float3 c=0;
 float2 p=rot(uv,wt*.08);
 for(int i=0;i<9;i++){float f=float(i);float2 q=p;q.y+=.22*sin(q.x*2+wt*.45+f*.55);float d=abs(q.y-(f-4)*.17);c+=palette(f*.08+q.x*.12+wt*.025)*.009/(d+.009);p=rot(p,.09);}
 // The original demo fades to black after 45 seconds. A disk scan can run
 // indefinitely, so keep the same waves alive with a slow, subtle breathing pulse.
 float fade=.82+.18*cos(t*.2);
 float grain=fract(sin(dot(v.p.xy,float2(12.9898,78.233)))*43758.5453);
 c=1-exp(-c*1.15);c*=max(0.,1-.18*dot(uv,uv));c=pow(max(c,0.),float3(.85));c=(c+(grain-.5)*.018)*fade;
 return float4(c,1);
}
