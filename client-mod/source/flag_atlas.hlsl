// OpenCJ country atlas: alpha carries a nonzero 8-bit cell selector.
// The sampled flag supplies output opacity; selector alpha must not dim it.
// Eight pages hold at most 36 flags each, below the 6 MiB image-loading buffer.
sampler2D colorMapSampler : register(s0);
float4 main(float2 uv : TEXCOORD0, float4 color : COLOR0) : COLOR
{
    float slot = floor(saturate(color.a) * 255.0 + 0.5) - 1.0;
    slot = max(0.0, slot);
    float row = floor(slot / 6.0);
    float col = slot - row * 6.0;
    float2 atlasUV = (float2(col, row) * 160.0 + 16.0 + uv * 128.0) / 1024.0;
    return tex2D(colorMapSampler, atlasUV);
}
