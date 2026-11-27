#include <metal_stdlib>
using namespace metal;

// tvOS port of the three parametric sculptures in macOS App/visualizer-art.js.
// Center, half-width and transverse bow describe every thread in one cross-section.
struct Section { float2 c, w, b; };
struct Piece { uint4 shape, mesh; };
struct Frame { float4 display, audio; }; // width, height, time, preset; bass, mid, treble, unit
struct Ink { float4 position [[position]]; float3 color; };
struct Grain { float4 position [[position]]; float3 color; float size [[point_size]]; };
constant uint rowStride = 180;
constant float tau = 6.28318530718;

static float2 rotate2(float2 p, float a) {
    float c = cos(a), s = sin(a);
    return float2(c*p.x-s*p.y, s*p.x+c*p.y);
}

static float2 world(float2 p, constant Frame &f) {
    uint id = uint(f.display.w);
    float t = f.display.z;
    if (id == 0) return rotate2((p - float2(.035,0))*float2(.96,.84), -.18 + .075*sin(t*.16));
    if (id == 1) return rotate2(p - float2(.11,.07), -.14 + .045*sin(t*.15));
    return rotate2(p*float2(.89,.85), -.26 + .06*sin(t*.12));
}

static float4 clip(float2 p, constant Frame &f) {
    return float4(world(p, f)*f.audio.w*float2(2,-2)/f.display.xy, 0, 1);
}

static float2 emberArm(Piece piece, constant Frame &f) {
    uint tier=piece.shape.y, k=piece.shape.z;
    float t=f.display.z;
    float size=tier == 0 ? 1. : (tier == 1 ? .58 : .29);
    float turn=tier == 0 ? .06 : (tier == 1 ? .48 : -.25);
    float az=k*tau/(tier == 1 ? 6. : 7.)+turn+.08*sin(t*.19+tier*2.)+.09*f.audio.y;
    float pulse=.5+.5*sin(k*2.4+t*.32);
    return float2(az,size*(.94+.07*pulse+.06*f.audio.x));
}

static Section emberSection(Piece piece, float u, constant Frame &f) {
    float2 arm=emberArm(piece,f);
    float t=f.display.z, k=piece.shape.z;
    float arc=max(0.,sin(M_PI_F*u)), r=arm.y*(.105+.88*pow(arc,1.12));
    float a=arm.x+1.05*u-.32*sin(tau*u)+.12*f.audio.y*sin(tau*u+.5)+.09*sin(t*.2+u*5+k)*arc;
    float2 radial=float2(cos(a),sin(a)), tangent=float2(-radial.y,radial.x);
    float twist=tau*u+.32*sin(t*.2+k)+.5, w=arm.y*(.016+.162*pow(arc,.75));
    return {r*radial, w*((.63*cos(twist)+.33)*radial+(.92*sin(twist)+.48)*tangent),
            w*(.42*radial-.56*tangent)*sin(twist-.6)};
}

static Section tidalSection(Piece piece, float u, constant Frame &f) {
    uint shell=piece.shape.y;
    float t=f.display.z;
    float a=u*12.65-5.82+.17*sin(t*.14)+.09*f.audio.y+shell*.1;
    float r=(.013+1.1*pow(u,1.93))*(1+.065*f.audio.x)*(1+shell*.13);
    float c=cos(a), s=sin(a);
    float w=(.004+.253*pow(u,1.24))*saturate((1-u)*9)*(shell ? .4 : 1.);
    float twist=a*.85+.37*sin(t*.23+a)+f.audio.y*.48;
    float radial=w*(.75+.62*cos(twist)), tangential=w*.78*sin(twist);
    return {float2(r*(1.23*c+.16*sin(2*a+.37))-.025,r*(.73*s+.085*sin(a*1.6+t*.39))),
            float2(radial*c-tangential*s,.85*(radial*s+tangential*c)),
            w*float2(.84*c+.62*s,.63*s-.73*c)*sin(twist+.85)};
}

static Section prismSection(Piece piece, float u, constant Frame &f) {
    float a=(piece.shape.y+u)*M_PI_F*.5, c=cos(a), s=sin(a), t=f.display.z, mid=f.audio.y;
    float phase=.16*sin(t*.21);
    float2 p=float2(1.18*s+.13*sin(3*a+.28)+.04*mid*sin(2*a+phase),
                    .48*sin(2*a+phase)+.16*c+.074*cos(3*a-t*.19));
    float2 d=float2(1.18*c+.39*cos(3*a+.28)+.08*mid*cos(2*a+phase),
                    .96*cos(2*a+phase)-.16*s-.222*sin(3*a-t*.19));
    float2 n=float2(-d.y,d.x)/max(.15,length(d));
    float twist=1.5*a+.52*sin(2*a)+.33*sin(t*.28)+.3*mid;
    float w=(.135+.118*pow(.5+.5*cos(2*a-.6),.85))*(1+.15*f.audio.x);
    Section row={p,w*(n*cos(twist)+float2(.33,-.84)*sin(twist)),
                 w*(n*.65+float2(.19,-.52))*cos(twist+.6)};
    if (piece.shape.w==1) {
        float bend=sin(M_PI_F*u);
        row.c+=-.76*row.w+float2(-.10,.17)*bend;
        row.w=row.w*.65+float2(.05,-.06)*bend;
        row.b*=.81;
    }
    return row;
}

static Section coil(float u, float2 origin, float heading, float2 size, float hand, float t) {
    float angle=heading-hand*1.82, a=hand*(u*10.6+.14*sin(t*.26+u*4));
    float start=hand*.14*sin(t*.26), r=pow(1-u,1.45);
    float2 d=float2(cos(a),sin(a)), tangent=float2(-d.y,d.x);
    float w=(.15*r+.012*(1-u))*min(1.,u*14);
    return {origin+rotate2(size*(r*d-float2(cos(start),sin(start))),angle),
            rotate2(size*w*(d+.61*tangent),angle),
            rotate2(-size*w*.69*tangent*sin(a*.8),angle)};
}

static Section sectionFor(Piece piece, float u, constant Frame &f) {
    uint id=piece.shape.x, branch=piece.shape.w, k=piece.shape.z;
    if (id==2) return prismSection(piece,u,f);
    if (id==0) {
        if (!branch) return emberSection(piece,u,f);
        float2 arm=emberArm(piece,f);
        uint steps=piece.shape.y ? 48 : 70;
        if (branch==2) {
            Section inner=emberSection(piece,16./steps,f);
            return coil(u,inner.c-inner.w,arm.x+.42,float2(.12,.08)*arm.y,1,f.display.z+k);
        }
        uint i=uint((steps+1)*.62);
        Section o=emberSection(piece,float(i)/steps,f);
        float2 d=emberSection(piece,float(i+1)/steps,f).c-o.c;
        float pulse=.5+.5*sin(k*2.4+f.display.z*.32);
        return coil(u,o.c+o.w,atan2(d.y,d.x),float2(.18+.04*pulse,.14)*arm.y,-1,f.display.z+k);
    }
    if (!branch) return tidalSection(piece,u,f);
    uint i=uint(round((.38+k*.079)*176));
    Section o=tidalSection(piece,float(i)/176,f);
    float2 d=tidalSection(piece,float(i+1)/176,f).c-o.c;
    return coil(u,o.c-.68*o.w,atan2(d.y,d.x)-.44,float2(1,.76)*(.05+.023*k),-1,f.display.z+k);
}

kernel void tdFilamentSections(uint2 tid [[thread_position_in_grid]], constant Frame &f [[buffer(0)]],
                               constant Piece *pieces [[buffer(1)]], device Section *rows [[buffer(2)]]) {
    Piece piece=pieces[tid.y];
    if (tid.x<=piece.mesh.x) rows[tid.y*rowStride+tid.x]=sectionFor(piece,float(tid.x)/piece.mesh.x,f);
}

static float3 rgb(uint value) {
    return float3((value>>16)&255,(value>>8)&255,value&255)/255.;
}

static float3 gradientInk(Piece p,float2 pos,constant Frame &f) {
    const uint ember[] = {0x50172f,0xe74944,0xffd593,0xfc8241,0x9c2043};
    const uint tidal[] = {0x3543a0,0x7385ff,0x87e2ee,0x0ee6c3,0x379bba,0x514097};
    const uint prism[] = {0xf65768,0xffb15a,0xa6d886,0x23cacc,0x4e69f1,0xaa58f4,0xefb87e};
    const float ep[]={0.,.21,.5,.7,1.}, tp[]={0.,.2,.43,.62,.84,1.}, pp[]={0.,.16,.33,.46,.62,.8,1.};
    uint id=p.shape.x;
    float2 a=float2(0),d;
    if(id==0) { float2 arm=emberArm(p,f); d=float2(cos(arm.x+.49),sin(arm.x+.49))*arm.y; }
    else if(id==1) { a=float2(-.89,-.55); d=float2(1.,.25)-a; }
    else { a=float2(-1.4,-.12); d=float2(1.34,.33)-a; }
    float x=saturate(dot(pos-a,d)/dot(d,d));
    uint count=id==0?5:(id==1?6:7);
    for(uint i=1;i<count;i++) {
        float right=id==0?ep[i]:(id==1?tp[i]:pp[i]);
        if(x<=right || i+1==count) {
            float left=id==0?ep[i-1]:(id==1?tp[i-1]:pp[i-1]);
            uint first=id==0?ember[i-1]:(id==1?tidal[i-1]:prism[i-1]);
            uint last=id==0?ember[i]:(id==1?tidal[i]:prism[i]);
            return mix(rgb(first),rgb(last),(x-left)/(right-left));
        }
    }
    return float3(0);
}

static float2 threadAt(Section row,float s) { return row.c+s*row.w+(1-s*s)*row.b; }

static float2 lightWidth(Piece p,constant Frame &f) {
    uint id=p.shape.x, layer=p.shape.y, k=p.shape.z, branch=p.shape.w;
    float high=f.audio.z;
    if(id==0) {
        if(branch) return float2(branch==2?.53:.72+.2*high,.00145);
        float pulse=.5+.5*sin(k*2.4+f.display.z*.32);
        return float2((layer?.75:.82)+.15*pulse+.15*high,layer?.00165:.0020);
    }
    if(id==1) {
        if(branch) return float2(.51+.12*high,.00145);
        return float2(layer?.26+.07*high:.98+.22*high,layer?.0018:.0026);
    }
    return float2(branch?.4+.1*high:((layer==0||layer==3)?.94:.70)+.22*high,branch?.0014:.0022);
}

// draw.x = piece index, draw.y = fill/thread/rib. Each thread is a continuous
// triangle strip; a centered tangent joins adjacent segments without cracks.
vertex Ink tdFilamentRibbon(uint v [[vertex_id]], uint instance [[instance_id]], constant Frame &f [[buffer(0)]],
                            constant Piece *pieces [[buffer(1)]], device const Section *data [[buffer(2)]],
                            constant uint2 &draw [[buffer(3)]]) {
    Piece p=pieces[draw.x]; device const Section *rows=data+draw.x*rowStride;
    float2 lw=lightWidth(p,f);
    float side=(v&1)?1.:-1., value=.105*lw.x;
    uint i=v/2;
    float2 point;
    if(draw.y==0) point=threadAt(rows[i],side);
    else {
        float thickness=lw.y;
        float2 delta;
        if(draw.y==1) {
            float fraction=float(instance)/(p.mesh.y-1), s=2*fraction-1;
            bool edge=instance==0 || instance+1==p.mesh.y;
            float glint=pow(.5+.5*cos(fraction*29+.7),8.);
            value=min(.95,lw.x*(edge?.9:.12+.23*abs(s)+.35*glint));
            thickness*=edge?1.75:.72+.65*glint;
            point=threadAt(rows[i],s);
            delta=threadAt(rows[min(i+1,p.mesh.x)],s)-threadAt(rows[i?i-1:0],s);
        } else {
            uint index=2+instance*p.mesh.z;
            float s=float(i)/4.-1;
            Section row=rows[index];
            point=threadAt(row,s); delta=row.w-2*s*row.b;
            value=lw.x*(.065+.1*pow(.5+.5*sin(index*.31),3.));
            thickness*=.68;
        }
        // Preserve subpixel energy at TV resolution, rather than letting a
        // hairline vanish in the gaps between pixel centers.
        float px=thickness*f.audio.w;
        value*=min(1.,px);
        float2 normal=float2(-delta.y,delta.x)/max(length(delta),.00001);
        point+=side*.5*max(thickness,1./f.audio.w)*normal;
    }
    return {clip(point,f),gradientInk(p,point,f)*value};
}

vertex Grain tdFilamentCaustics(uint i [[vertex_id]], constant Frame &f [[buffer(0)]],
                                constant Piece *pieces [[buffer(1)]], device const Section *data [[buffer(2)]],
                                constant uint2 &draw [[buffer(3)]], device const float4 *seeds [[buffer(4)]]) {
    Piece p=pieces[draw.x]; device const Section *rows=data+draw.x*rowStride;
    float4 seed=seeds[i]; float x=seed.x*p.mesh.x; uint j=min(uint(x),p.mesh.x-1);
    Section a=rows[j], b=rows[j+1];
    float2 pos=mix(a.c,b.c,fract(x))+seed.y*a.w+max(0.,1-seed.y*seed.y)*a.b;
    float alpha=p.shape.x==0?.38+.21*f.audio.z:(p.shape.x==1?.55+.24*f.audio.z:.48+.21*f.audio.z);
    float px=f.audio.w*seed.z;
    return {clip(pos,f),gradientInk(p,pos,f)*alpha*min(1.,px*px),max(1.,px)};
}

// The same deterministic log-density flame material as the Mac, warped
// through each local ribbon frame. Additive subpixel splats gather its light.
vertex Grain tdFilamentFlame(uint i [[vertex_id]], constant Frame &f [[buffer(0)]],
                             constant Piece *pieces [[buffer(1)]], device const Section *data [[buffer(2)]],
                             constant uint2 &draw [[buffer(3)]], device const float4 *material [[buffer(4)]],
                             constant float4 &patch [[buffer(5)]]) {
    Piece p=pieces[draw.x]; device const Section *rows=data+draw.x*rowStride;
    float4 sample=material[i];
    float span=(patch.y-patch.x)*p.mesh.x, u=sample.x*span+patch.x*p.mesh.x;
    uint j=min(uint(u),p.mesh.x-1);
    Section a=rows[j],b=rows[j+1]; float2 c=a.c+.49*a.b, d=b.c+.49*b.b-c;
    float2 pos=c+fract(u)*d+patch.z*sample.y*mix(a.w,b.w,fract(u));
    float fieldScale=min(1.,720./max(f.display.x,f.display.y)), fieldUnit=f.audio.w*fieldScale;
    float determinant=p.shape.x==0?.96*.84:(p.shape.x==2?.89*.85:1.);
    float footprint=2*span*abs(d.x*a.w.y-d.y*a.w.x)*abs(patch.z)*determinant*fieldUnit*fieldUnit/(520.*184.);
    float gain=patch.w*min(1.6,.008+1.35*footprint);
    uint id=p.shape.x;
    float3 ca=rgb(id==0?0xc53857:(id==1?0x4950dc:0x9747f8));
    float3 cb=rgb(id==0?0xffa651:(id==1?0x2bdecb:0x46e1df));
    float3 cc=rgb(id==0?0xffe1a3:(id==1?0xacf6ff:0xfab16e));
    float shade=sample.w;
    float3 color=shade<.5?mix(ca,cb,shade*2):mix(cb,cc,shade*2-1);
    return {clip(pos,f),color*(.068+.88*sample.z)*gain,2./fieldScale};
}

vertex Grain tdFilamentDust(uint i [[vertex_id]],constant Frame &f [[buffer(0)]],device const float4 *seeds [[buffer(4)]]) {
    float4 d=seeds[i]; uint id=uint(f.display.w);
    uint hi=id==0?0xffd19a:(id==1?0xc0fff2:0xf8c785);
    uint lo=id==0?0xfc663a:(id==1?0x18d9bc:0x68c7c2);
    float px=f.audio.w*2*d.z;
    return {float4(d.x,-d.y,0,1),rgb(i%5==0?hi:lo)*d.w*min(1.,px*px),max(1.,px)};
}

fragment float4 tdFilamentColor(Ink in [[stage_in]]) { return float4(in.color,1); }
fragment float4 tdFilamentPoint(Grain in [[stage_in]]) { return float4(in.color,1); }
fragment float4 tdFilamentSplat(Grain in [[stage_in]],float2 uv [[point_coord]]) {
    float2 weights=1.-abs(2.*uv-1.);
    return float4(in.color*weights.x*weights.y,1);
}

struct Screen { float4 position [[position]]; float2 uv; };
vertex Screen tdFilamentScreen(uint v [[vertex_id]]) {
    float2 uv=float2((v<<1)&2,v&2);
    return {float4(uv*float2(2,-2)+float2(-1,1),0,1),uv};
}
static float halo(float r) {
    if (r<.28) return mix(174./255.,83./255.,r/.28);
    if (r<.62) return mix(83./255.,24./255.,(r-.28)/.34);
    return (24./255.)*saturate((1.-r)/.38);
}
fragment float4 tdFilamentBackdrop(Screen in [[stage_in]],constant Frame &f [[buffer(0)]]) {
    float2 p=(in.uv-.5)*f.display.xy/f.audio.w; uint id=uint(f.display.w);
    float3 base=rgb(id==0?0x070307:(id==1?0x01060e:0x080711));
    base=mix(base,rgb(id==0?0x421321:(id==1?0x0b2846:0x342448)),.7*halo(length(p-float2(-.32,.08))/1.92));
    base=mix(base,rgb(id==0?0x9e2640:(id==1?0x145598:0x8f65f7)),.16*halo(length(p-float2(1.48,-.73))/1.45));
    float low=f.audio.x,t=f.display.z;
    if (id==0) {
        p=rotate2(p,.18-.075*sin(t*.16))/float2(.96,.84)+float2(.035,0);
        base+=rgb(0xc73e27)*halo(length(p)/1.12)*(.43+.17*low)+rgb(0xf9af61)*halo(length(p)/.135)*(.5+.27*low);
    } else if(id==1) {
        p=rotate2(p,.14-.045*sin(t*.15))+float2(.11,.07);
        base+=rgb(0x1a7092)*halo(length(p-float2(-.1,.05))/1.19)*(.43+.17*low);
    } else {
        p=rotate2(p,.26-.06*sin(t*.12))/float2(.89,.85);
        base+=rgb(0xbe724f)*halo(length(p-float2(-.53,.16))/.89)*(.26+.08*low);
        base+=rgb(0x6554ac)*halo(length(p-float2(.58,-.13))/1.03)*(.40+.13*low);
    }
    return float4(base,1);
}
fragment float4 tdFilamentBloom(Screen in [[stage_in]],texture2d<float> scene [[texture(0)]]) {
    constexpr sampler samp(coord::normalized,address::clamp_to_edge,filter::linear,mip_filter::linear);
    float3 sharp=scene.sample(samp,in.uv,level(0)).rgb;
    float3 glow=scene.sample(samp,in.uv,level(4)).rgb;
    return float4(sharp+.61*(1.-sharp)*glow,1);
}
