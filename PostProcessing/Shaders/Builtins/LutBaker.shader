Shader "Hidden/PostProcessing/LutBaker"
{
    HLSLINCLUDE

        #pragma target 3.0
        #include "../StdLib.hlsl"
        #include "../Colors.hlsl"
        #include "../ACES.hlsl"
        
        #pragma multi_compile __ TONEMAPPING_ACES TONEMAPPING_NEUTRAL TONEMAPPING_CUSTOM

        TEXTURE2D_SAMPLER2D(_BaseLut, sampler_BaseLut);
        float4 _Lut2D_Params;

        float3 _CustomToneCurve;
        float _ToeSegment[6];
        float _MidSegment[6];
        float _ShoSegment[6];

        float3 _ColorBalance;
        float3 _ColorFilter;
        float _HueShift;
        float _Saturation;
        float _Contrast;
        float _Brightness;

        float3 _ChannelMixerRed;
        float3 _ChannelMixerGreen;
        float3 _ChannelMixerBlue;

        float3 _Lift;
        float3 _InvGamma;
        float3 _Gain;

        TEXTURE2D_SAMPLER2D(_Curves, sampler_Curves);

        // -----------------------------------------------------------------------------------------
        // HDR Grading - empty, default lut

        float4 FragNoGradingHDR(VaryingsDefault i) : SV_Target
        {
            // 2D strip lut
            float3 colorLutSpace = GetLutStripValue(i.texcoord, _Lut2D_Params);

            // Switch back to unity linear
            float3 colorLinear = LUT_SPACE_DECODE(colorLutSpace);

            return float4(colorLinear, 1.0);
        }

        // -----------------------------------------------------------------------------------------
        // HDR Grading

        float3 ColorGradeHDR(float3 colorLinear)
        {
            float3 aces = unity_to_ACES(colorLinear);

            // ACEScc (log) space
            float3 acescc = ACES_to_ACEScc(aces);

            // Contrast feels a lot more natural when done in log rather than doing it in linear
            acescc = Contrast(acescc, ACEScc_MIDGRAY, _Contrast);

            aces = ACEScc_to_ACES(acescc);

            // ACEScg (linear) space
            float3 acescg = ACES_to_ACEScg(aces);

            acescg = WhiteBalance(acescg, _ColorBalance);
            acescg *= _ColorFilter;
            acescg = ChannelMixer(acescg, _ChannelMixerRed, _ChannelMixerGreen, _ChannelMixerBlue);
            acescg = LiftGammaGainHDR(acescg, _Lift, _InvGamma, _Gain);

            float3 hsv = RgbToHsv(acescg);
            float satMult = SecondaryHueSat(hsv.x, TEXTURE2D_PARAM(_Curves, sampler_Curves));
            satMult *= SecondarySatSat(hsv.y, TEXTURE2D_PARAM(_Curves, sampler_Curves));
            satMult *= SecondaryLumSat(Luminance(acescg), TEXTURE2D_PARAM(_Curves, sampler_Curves));
            hsv.x = SecondaryHueHue(hsv.x + _HueShift, TEXTURE2D_PARAM(_Curves, sampler_Curves));
            acescg = HsvToRgb(hsv);

            acescg = Saturation(acescg, _Saturation * satMult);

            // Tonemap
            #if TONEMAPPING_ACES
            {
                aces = ACEScg_to_ACES(acescg);
                colorLinear = AcesTonemap(aces);
            }
            #elif TONEMAPPING_NEUTRAL
            {
                colorLinear = ACEScg_to_unity(acescg);
                colorLinear = NeutralTonemap(colorLinear);
            }
            #elif TONEMAPPING_CUSTOM
            {
                colorLinear = ACEScg_to_unity(acescg);
                colorLinear = CustomTonemap(colorLinear, _CustomToneCurve, _ToeSegment, _MidSegment, _ShoSegment);
            }
            #else
            {
                colorLinear = ACEScg_to_unity(acescg);
            }
            #endif

            return colorLinear;
        }

        float4 FragHDR(VaryingsDefault i) : SV_Target
        {
            // 2D strip lut
            float3 colorLutSpace = GetLutStripValue(i.texcoord, _Lut2D_Params);

            // Switch back to unity linear and color grade
            float3 colorLinear = LUT_SPACE_DECODE(colorLutSpace);
            float3 graded = ColorGradeHDR(colorLinear);

            return float4(graded, 1.0);
        }

        // -----------------------------------------------------------------------------------------
        // LDR Grading - no starting lut

        float3 ColorGradeLDR(float3 colorLinear)
        {
            const float kMidGrey = pow(0.5, 2.2);

            colorLinear *= _Brightness;
            colorLinear = Contrast(colorLinear, kMidGrey, _Contrast);
            colorLinear = WhiteBalance(colorLinear, _ColorBalance);
            colorLinear *= _ColorFilter;
            colorLinear = ChannelMixer(colorLinear, _ChannelMixerRed, _ChannelMixerGreen, _ChannelMixerBlue);
            colorLinear = LiftGammaGainLDR(colorLinear, _Lift, _InvGamma, _Gain);

            float3 hsv = RgbToHsv(colorLinear);
            float satMult = SecondaryHueSat(hsv.x, TEXTURE2D_PARAM(_Curves, sampler_Curves));
            satMult *= SecondarySatSat(hsv.y, TEXTURE2D_PARAM(_Curves, sampler_Curves));
            satMult *= SecondaryLumSat(Luminance(colorLinear), TEXTURE2D_PARAM(_Curves, sampler_Curves));
            hsv.x = SecondaryHueHue(hsv.x + _HueShift, TEXTURE2D_PARAM(_Curves, sampler_Curves));
            colorLinear = HsvToRgb(hsv);

            colorLinear = Saturation(colorLinear, _Saturation * satMult);
            colorLinear = saturate(colorLinear);
            colorLinear = YrgbCurve(colorLinear, TEXTURE2D_PARAM(_Curves, sampler_Curves));

            return saturate(colorLinear);
        }

        float4 FragLDRFromScratch(VaryingsDefault i) : SV_Target
        {
            // 2D strip lut
            float3 colorLinear = GetLutStripValue(i.texcoord, _Lut2D_Params);
            float3 graded = ColorGradeLDR(colorLinear);
            return float4(graded, 1.0);
        }

    ENDHLSL

    SubShader
    {
        Cull Off ZWrite Off ZTest Always

        Pass
        {
            HLSLPROGRAM

                #pragma vertex VertDefault
                #pragma fragment FragNoGradingHDR

            ENDHLSL
        }

        Pass
        {
            HLSLPROGRAM

                #pragma vertex VertDefault
                #pragma fragment FragHDR

            ENDHLSL
        }

        Pass
        {
            HLSLPROGRAM

                #pragma vertex VertDefault
                #pragma fragment FragLDRFromScratch

            ENDHLSL
        }
    }
}