#include <metal_stdlib>
using namespace metal;

struct KaleidoscopeUniforms {
    float4 frame; // width, height, playback time, preset
    float4 audio; // bass, mid, treble, unused
};

vertex float4 tvKaleidoscopeVertex(uint index [[vertex_id]]) {
    return float4(index == 1 ? 3.0 : -1.0, index == 2 ? 3.0 : -1.0, 0, 1);
}

// Fold all sectors into the same wedge, alternating their handedness.
static float foldAngle(float angle, float mirrors) {
    float halfWedge = M_PI_F / mirrors;
    return abs(angle - (2.0 * halfWedge) * floor((angle + halfWedge) / (2.0 * halfWedge)));
}

static float3 palette(float phase, float3 shift) {
    return 0.56 + 0.44 * cos(phase + shift);
}

static float contour(float distance, float width) {
    return 1.0 - smoothstep(width * 0.45, width, abs(distance));
}

static float2 reflectedUV(float2 point) {
    return 1.0 - abs(2.0 * fract(point * 0.5) - 1.0);
}

static float3 mirroredStage(float radius, float angle, float time, float3 audio,
                            texture2d<float> image) {
    float wedge = foldAngle(angle - time * 0.039 + radius * 0.10, 7.0);
    float2 slice = radius * float2(cos(wedge), sin(wedge));
    float2 uv = float2(0.35 + time * 0.016, 0.58 + sin(time * 0.13) * 0.09)
              + slice * float2(0.88 - 0.08 * audio.x, 1.52);
    constexpr sampler samplePhoto(filter::linear);
    float3 photo = image.sample(samplePhoto, reflectedUV(uv)).rgb;
    float prism = sin(slice.x * 21.0 + slice.y * 28.0 - time * 1.1);
    float3 color = pow(photo, float3(0.83)) * (1.04 + 0.20 * audio.y);
    color += palette(radius * 13.0 - time * 0.55, float3(0.1, 2.9, 4.8))
           * (0.045 + 0.11 * contour(prism, 0.105));
    return color * (0.92 + 0.08 * cos(wedge * 14.0));
}

static float3 stainedGlass(float radius, float angle, float time, float3 audio) {
    float wedge = foldAngle(angle - time * 0.026, 12.0);
    float expanding = radius * (1.0 - 0.068 * audio.x);
    float2 slice = expanding * float2(cos(wedge), sin(wedge));
    float2 mesh = float2(slice.x * 12.0 + slice.y * 6.0, slice.y * 22.0 - slice.x * 2.8);
    mesh.x += 0.32 * sin(radius * 5.0 - time * 0.7);
    mesh.y += time * 0.18;
    float2 tile = fract(mesh);
    float diagonal = tile.x + tile.y - 1.0;
    float edge = min(min(min(tile.x, 1.0 - tile.x), min(tile.y, 1.0 - tile.y)), abs(diagonal) * 0.75);
    float facet = dot(floor(mesh), float2(0.93, 1.62)) + step(0.0, diagonal) * 1.8;
    float3 tint = palette(facet + radius * 2.0 + time * 0.25, float3(1.2, 3.65, 5.4));
    float shimmer = sin(tile.x * 32.0 + tile.y * 21.0) * sin(tile.y * 49.0 - tile.x * 13.0);
    float polished = 0.32 + 0.62 * pow(1.0 - abs(tile.x - tile.y), 3.0) + shimmer * 0.085;
    float3 color = tint * polished * smoothstep(0.017, 0.067, edge);
    color += mix(tint, float3(0.96, 0.81, 0.49), 0.55)
           * exp(-abs(edge - 0.064) * 28.0) * (0.32 + audio.z * 0.24);
    color += float3(0.52, 0.36, 0.75) * exp(-radius * 7.0);
    return color;
}

static float3 neonBloom(float radius, float angle, float time, float3 audio) {
    float wedge = foldAngle(angle + time * 0.031, 8.0);
    float r = radius * (1.0 - audio.x * 0.09);
    float petal = cos(wedge * 8.0);
    float curl = sin(r * 10.0 - time * 0.93) * (0.28 + 0.10 * audio.y);
    float iris = r * 15.0 + petal * (1.8 + sin(time * 0.29) * 0.48) + curl;
    float crossing = r * 23.0 - petal * 1.75 + curl - time * 0.62;
    float ribbon = sin(iris) * 0.64 + 0.36 * sin(crossing);
    float3 orchid = palette(r * 7.3 + petal * 1.25 + time * 0.4, float3(0.7, 3.7, 5.65));
    float3 mint = palette(r * 9.2 - time * 0.36, float3(3.8, 5.4, 0.0));
    float glow = exp(-abs(ribbon) * 5.5);
    float spine = contour(ribbon, 0.09 + 0.06 * audio.z);
    float threads = contour(sin(iris * 2.75 + curl * 0.8), 0.17);
    float3 color = orchid * (0.065 + 0.49 * glow)
                 + mix(orchid, mint, 0.58) * (0.54 * spine + 0.23 * threads);
    color += float3(0.82, 0.65, 1.0) * exp(-r * 11.0) * (0.62 + audio.x * 0.33);
    return color;
}

// Repeated diamond gates shrink with perspective and advance toward the viewer.
static float3 mirrorTunnel(float radius, float angle, float time, float3 audio) {
    float wedge = foldAngle(angle - time * 0.035 + 0.055 * sin(time * 0.26), 4.0);
    float diamond = radius * (cos(wedge) + sin(wedge) * 0.72);
    float depth = -log2(diamond + 0.028) * 2.35 + time * 0.72 + audio.x * 0.28;
    float gate = fract(depth);
    float face = wedge / (M_PI_F / 4.0);
    float seam = abs(fract(face * 4.0) - 0.5);
    float rib = contour(gate - 0.20, 0.048 + 0.025 * audio.z);
    float halo = exp(-abs(gate - 0.20) * 12.0);
    float farEdge = contour(gate - 0.69, 0.036);
    float alternation = 0.5 + 0.5 * cos(floor(depth) * M_PI_F);
    float3 teal = float3(0.075, 0.86, 0.87);
    float3 violet = float3(0.62, 0.28, 0.98);
    float3 tint = mix(teal, violet, smoothstep(0.10, 0.88, face) * 0.67 + alternation * 0.26);
    float visibility = smoothstep(0.015, 0.19, diamond);
    float panel = (0.10 + 0.16 * cos(gate * M_PI_F)) * (0.72 + 0.28 * cos(face * 17.0));
    float rays = contour(seam, 0.079) * (0.09 + 0.13 * halo);
    float3 color = tint * (0.11 + panel + 0.58 * halo + 0.58 * rib + 0.34 * farEdge + rays);
    color = mix(float3(0.040, 0.025, 0.092), color, visibility);
    return color + float3(0.36, 0.63, 0.80) * exp(-diamond * 8.0) * (0.30 + 0.24 * audio.y);
}

// Two smooth color fields braid through a rotating set of mirrored wedges.
static float3 auroraWeave(float radius, float angle, float time, float3 audio) {
    float wedge = foldAngle(angle + time * 0.020, 5.0);
    float2 slice = radius * float2(cos(wedge), sin(wedge));
    float bend = sin(slice.x * 8.7 - time * 0.72) * 1.15;
    float flow = 20.0 * slice.y + bend + 0.8 * sin(radius * 11.0 + time * 0.42);
    float crossflow = 11.0 * slice.x - 26.0 * slice.y + sin(flow * 0.52 + time * 0.36);
    float band = cos(flow - audio.x * 0.72);
    float crossing = cos(crossflow + time * 0.58);
    float weave = smoothstep(-0.85, 0.79, crossing);
    float crest = pow(0.5 + 0.5 * band, 4.0);
    float strand = smoothstep(0.55, 1.0, crossing);
    float filaments = 0.5 + 0.5 * cos(flow * 4.0 + 2.5 * sin(crossflow));
    float3 ice = float3(0.13, 0.63, 0.96);
    float3 mint = float3(0.24, 0.97, 0.59);
    float3 lilac = float3(0.62, 0.32, 0.91);
    float3 ribbon = mix(ice, mint, 0.5 + 0.5 * sin(radius * 5.0 + time * 0.39));
    float3 color = float3(0.033, 0.074, 0.129);
    color += ribbon * (0.23 * (0.5 + 0.5 * band) + crest * (0.39 + 0.27 * weave + audio.y * 0.11));
    color += lilac * strand * (0.23 + 0.32 * (1.0 - crest));
    color += float3(0.56, 0.92, 0.85) * crest * filaments * (0.12 + audio.z * 0.14);
    return color;
}

// Radial scoring and amber highlights give the moving iris a machined finish.
static float3 obsidianIris(float radius, float angle, float time, float3 audio) {
    float wedge = foldAngle(angle - time * 0.027, 7.0);
    float petal = 0.5 + 0.5 * cos(wedge * 7.0);
    float aperture = 0.16 + 0.072 * petal + 0.054 * audio.x + 0.024 * sin(time * 0.77);
    float iris = radius - aperture;
    float etching = sin(iris * 35.0 + petal * 6.0 + time * 0.53);
    float groove = 0.5 + 0.5 * cos(iris * 22.0 - petal * 7.8 - time * 0.36);
    float metal = (0.24 + 0.43 * petal + 0.34 * groove) * smoothstep(0.0, 0.15, iris);
    float shoulder = contour(iris - 0.28 - petal * 0.11, 0.041);
    float rim = exp(-abs(iris) * 33.0) + 0.54 * contour(iris - 0.064, 0.020);
    float hairline = contour(etching, 0.10 + audio.z * 0.11) * (0.14 + 0.10 * groove);
    float3 bronze = float3(0.66, 0.25, 0.073);
    float3 amber = float3(1.0, 0.73, 0.30);
    float3 steel = float3(0.18, 0.24, 0.32);
    float3 color = float3(0.026, 0.021, 0.033);
    color += mix(steel, bronze, groove) * metal * (0.73 + 0.20 * audio.y);
    color += amber * (0.81 * rim + 0.31 * shoulder + hairline * smoothstep(0.04, 0.15, iris));
    return color;
}

fragment half4 tvKaleidoscopeFragment(float4 position [[position]],
                                       constant KaleidoscopeUniforms &uniforms [[buffer(0)]],
                                       texture2d<float> photograph [[texture(0)]]) {
    float2 point = (position.xy - uniforms.frame.xy * float2(0.5, 0.46)) / (uniforms.frame.y * 0.65);
    float radius = length(point);
    float angle = atan2(point.y, point.x);
    float time = uniforms.frame.z;
    float3 audio = saturate(uniforms.audio.xyz);
    float3 color;
    if (uniforms.frame.w < 0.5 && !is_null_texture(photograph)) {
        color = mirroredStage(radius, angle, time, audio, photograph);
    } else if (uniforms.frame.w < 1.5) {
        color = stainedGlass(radius, angle, time, audio);
    } else if (uniforms.frame.w < 2.5) {
        color = neonBloom(radius, angle, time, audio);
    } else if (uniforms.frame.w < 3.5) {
        color = mirrorTunnel(radius, angle, time, audio);
    } else if (uniforms.frame.w < 4.5) {
        color = auroraWeave(radius, angle, time, audio);
    } else {
        color = obsidianIris(radius, angle, time, audio);
    }
    // Quiet the edges so the transport panel and title stay readable.
    float edge = 1.0 - 0.51 * smoothstep(0.49, 1.51, radius);
    float bottom = 1.0 - 0.74 * smoothstep(0.68, 1.0, position.y / uniforms.frame.y);
    return half4(half3(saturate(color * edge * bottom)), 1);
}
