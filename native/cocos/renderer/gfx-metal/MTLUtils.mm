/****************************************************************************
Copyright (c) 2020 Xiamen Yaji Software Co., Ltd.

http://www.cocos2d-x.org

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
****************************************************************************/
#include "MTLStd.h"

#include "MTLDevice.h"
#include "MTLGPUObjects.h"
#include "MTLPipelineState.h"
#include "MTLRenderPass.h"
#include "MTLShader.h"
#include "MTLUtils.h"
#include "StandAlone/ResourceLimits.h"
#include "TargetConditionals.h"
#include "gfx/GFXDef.h"
#include "glslang/SPIRV/GlslangToSpv.h"
#include "spirv_cross/spirv_msl.hpp"
#include <vector>

namespace cc {
namespace gfx {
namespace {

EShLanguage getShaderStage(ShaderStageFlagBit type) {
    switch (type) {
        case ShaderStageFlagBit::VERTEX: return EShLangVertex;
        case ShaderStageFlagBit::CONTROL: return EShLangTessControl;
        case ShaderStageFlagBit::EVALUATION: return EShLangTessEvaluation;
        case ShaderStageFlagBit::GEOMETRY: return EShLangGeometry;
        case ShaderStageFlagBit::FRAGMENT: return EShLangFragment;
        case ShaderStageFlagBit::COMPUTE: return EShLangCompute;
        default: {
            CCASSERT(false, "Unsupported ShaderStageFlagBit, convert to EShLanguage failed.");
            return EShLangVertex;
        }
    }
}

glslang::EShTargetClientVersion getClientVersion(int vulkanMinorVersion) {
    switch (vulkanMinorVersion) {
        case 0: return glslang::EShTargetVulkan_1_0;
        case 1: return glslang::EShTargetVulkan_1_1;
        case 2: return glslang::EShTargetVulkan_1_2;
        default: {
            CCASSERT(false, "Unsupported vulkan version, convert to EShTargetClientVersion failed.");
            return glslang::EShTargetVulkan_1_0;
        }
    }
}

glslang::EShTargetLanguageVersion getTargetVersion(int vulkanMinorVersion) {
    switch (vulkanMinorVersion) {
        case 0: return glslang::EShTargetSpv_1_0;
        case 1: return glslang::EShTargetSpv_1_3;
        case 2: return glslang::EShTargetSpv_1_5;
        default: {
            CCASSERT(false, "Unsupported vulkan version, convert to EShTargetLanguageVersion failed.");
            return glslang::EShTargetSpv_1_0;
        }
    }
}

const vector<unsigned int> GLSL2SPIRV(ShaderStageFlagBit type, const String &source, int vulkanMinorVersion = 2) {
    static bool glslangInitialized = false;
    if (!glslangInitialized) {
        glslang::InitializeProcess();
        glslangInitialized = true;
    }
    vector<unsigned int> spirv;
    auto stage = getShaderStage(type);
    auto string = source.c_str();
    glslang::TShader shader(stage);
    shader.setStrings(&string, 1);

    //Set up Vulkan/SpirV Environment
    int clientInputSemanticsVersion = 100 + vulkanMinorVersion * 10;                        // maps to, say, #define VULKAN 120
    glslang::EShTargetClientVersion clientVersion = getClientVersion(vulkanMinorVersion);   // map to, say, Vulkan 1.2
    glslang::EShTargetLanguageVersion targetVersion = getTargetVersion(vulkanMinorVersion); // maps to, say, SPIR-V 1.5

    shader.setEnvInput(glslang::EShSourceGlsl, stage, glslang::EShClientVulkan, clientInputSemanticsVersion);
    shader.setEnvClient(glslang::EShClientVulkan, clientVersion);
    shader.setEnvTarget(glslang::EShTargetSpv, targetVersion);

    EShMessages messages = (EShMessages)(EShMsgSpvRules | EShMsgVulkanRules);

    if (!shader.parse(&glslang::DefaultTBuiltInResource, clientInputSemanticsVersion, false, messages)) {
        CC_LOG_ERROR("GLSL Parsing Failed:\n%s\n%s", shader.getInfoLog(), shader.getInfoDebugLog());
        CC_LOG_ERROR("%s", string);
        return spirv;
    }

    glslang::TProgram program;
    program.addShader(&shader);

    if (!program.link(messages)) {
        CC_LOG_ERROR("GLSL Linking Failed:\n%s\n%s", program.getInfoLog(), program.getInfoDebugLog());
        CC_LOG_ERROR("%s", string);
        return spirv;
    }

    spv::SpvBuildLogger logger;
    glslang::SpvOptions spvOptions;
    glslang::GlslangToSpv(*program.getIntermediate(stage), spirv, &logger, &spvOptions);
    if (!spirv.size()) {
        CC_LOG_ERROR("GlslangToSpv Failed:\n%s\n%s", program.getInfoLog(), program.getInfoDebugLog());
        CC_LOG_ERROR("%s", string);
        return spirv;
    }
    return spirv;
}

//See more details at https://developer.apple.com/documentation/metal/mtlfeatureset
enum class GPUFamily {
    Apple1, // A7,
    Apple2, // A8
    Apple3, // A9, A10
    Apple4, // A11
    Apple5, // A12
    Apple6, // A13

    Mac1,
    Mac2,
};
}

namespace mu {
MTLResourceOptions toMTLResourseOption(MemoryUsage usage) {
    if (usage & MemoryUsage::HOST && usage & MemoryUsage::DEVICE)
        return MTLResourceStorageModeShared;
    else if (usage & MemoryUsage::DEVICE)
        return MTLResourceStorageModePrivate;
    else
#if (CC_PLATFORM == CC_PLATFORM_MAC_IOS)
        return MTLResourceStorageModeShared;
#else
        return MTLResourceStorageModeManaged;
#endif
}

MTLLoadAction toMTLLoadAction(LoadOp op) {
    switch (op) {
        case LoadOp::CLEAR: return MTLLoadActionClear;
        case LoadOp::LOAD: return MTLLoadActionLoad;
        case LoadOp::DISCARD: return MTLLoadActionDontCare;
        default: return MTLLoadActionDontCare;
    }
}

MTLStoreAction toMTLStoreAction(StoreOp op) {
    switch (op) {
        case StoreOp::STORE: return MTLStoreActionStore;
        case StoreOp::DISCARD: return MTLStoreActionDontCare;
        default: return MTLStoreActionDontCare;
    }
}

MTLClearColor toMTLClearColor(const Color &clearColor) {
    MTLClearColor mtlColor;
    mtlColor = MTLClearColorMake(clearColor.x, clearColor.y, clearColor.z, clearColor.w);
    return MTLClearColorMake(clearColor.x, clearColor.y, clearColor.z, clearColor.w);
}

MTLVertexFormat toMTLVertexFormat(Format format, bool isNormalized) {
    switch (format) {
        case Format::R32F: return MTLVertexFormatFloat;
        case Format::R32I: return MTLVertexFormatInt;
        case Format::R32UI: return MTLVertexFormatUInt;
        case Format::RG8: return isNormalized ? MTLVertexFormatUChar2Normalized : MTLVertexFormatUChar2;
        case Format::RG8I: return isNormalized ? MTLVertexFormatChar2Normalized : MTLVertexFormatChar2;
        case Format::RG16F: return MTLVertexFormatHalf2;
        case Format::RG16UI: return isNormalized ? MTLVertexFormatUShort2Normalized : MTLVertexFormatUShort2;
        case Format::RG16I: return isNormalized ? MTLVertexFormatShort2Normalized : MTLVertexFormatShort2;
        case Format::RG32I: return MTLVertexFormatInt2;
        case Format::RG32UI: return MTLVertexFormatUInt2;
        case Format::RG32F: return MTLVertexFormatFloat2;
        case Format::RGB8: return isNormalized ? MTLVertexFormatUChar3Normalized : MTLVertexFormatUChar3;
        case Format::RGB8I: return isNormalized ? MTLVertexFormatChar3Normalized : MTLVertexFormatChar3;
        case Format::RGB16I: return isNormalized ? MTLVertexFormatShort3Normalized : MTLVertexFormatShort3;
        case Format::RGB16UI: return isNormalized ? MTLVertexFormatUShort3Normalized : MTLVertexFormatUShort3;
        case Format::RGB16F: return MTLVertexFormatHalf3;
        case Format::RGB32I: return MTLVertexFormatInt3;
        case Format::RGB32UI: return MTLVertexFormatUInt3;
        case Format::RGB32F: return MTLVertexFormatFloat3;
        case Format::RGBA8: return isNormalized ? MTLVertexFormatUChar4Normalized : MTLVertexFormatUChar4;
        case Format::RGBA8I: return isNormalized ? MTLVertexFormatChar4Normalized : MTLVertexFormatChar4;
        case Format::RGBA16I: return isNormalized ? MTLVertexFormatShort4Normalized : MTLVertexFormatShort4;
        case Format::RGBA16UI: return isNormalized ? MTLVertexFormatUShort4Normalized : MTLVertexFormatUShort4;
        case Format::RGBA16F: return MTLVertexFormatHalf4;
        case Format::RGBA32I: return MTLVertexFormatInt4;
        case Format::RGBA32UI: return MTLVertexFormatUInt4;
        case Format::RGBA32F: return MTLVertexFormatFloat4;
        case Format::RGB10A2: return isNormalized ? MTLVertexFormatInt1010102Normalized : MTLVertexFormatInvalid;
        case Format::RGB10A2UI: return isNormalized ? MTLVertexFormatUInt1010102Normalized : MTLVertexFormatInvalid;
        case Format::BGRA8: {
#if CC_PLATFORM == CC_PLATFORM_MAC_IOS
            if (@available(iOS 11.0, *)) {
                if (isNormalized) {
                    return MTLVertexFormatUChar4Normalized_BGRA;
                } else {
                    CC_LOG_ERROR("Invalid metal vertex format %u", format);
                    return MTLVertexFormatInvalid;
                }
            }
#else
            if (@available(macOS 10.13, *)) {
                if (isNormalized) {
                    return MTLVertexFormatUChar4Normalized_BGRA;
                } else {
                    CC_LOG_ERROR("Invalid metal vertex format %u", format);
                    return MTLVertexFormatInvalid;
                }
            }
#endif
        }
        default: {
            CC_LOG_ERROR("Invalid vertex format %u", format);
            return MTLVertexFormatInvalid;
        }
    }
}

Format convertGFXPixelFormat(Format format) {
    switch (format) {
        case Format::RGB8: return Format::RGBA8;
        case Format::RGB32F: return Format::RGBA32F;
        default: return format;
    }
}

MTLPixelFormat toMTLPixelFormat(Format format) {
    switch (format) {
        case Format::A8: return MTLPixelFormatA8Unorm;
        case Format::R8: return MTLPixelFormatR8Uint;
        case Format::R8SN: return MTLPixelFormatR8Snorm;
        case Format::R8UI: return MTLPixelFormatR8Uint;
        case Format::R16F: return MTLPixelFormatR16Float;
        case Format::R32F: return MTLPixelFormatR32Float;
        case Format::R32UI: return MTLPixelFormatR32Uint;
        case Format::R32I: return MTLPixelFormatR32Sint;

        case Format::RG8: return MTLPixelFormatRG8Unorm;
        case Format::RG8SN: return MTLPixelFormatRG8Snorm;
        case Format::RG8UI: return MTLPixelFormatRG8Uint;
        case Format::RG8I: return MTLPixelFormatRG8Sint;
        case Format::RG16F: return MTLPixelFormatRG16Float;
        case Format::RG16UI: return MTLPixelFormatRG16Uint;
        case Format::RG16I:
            return MTLPixelFormatRG16Sint;

            //            case Format::RGB8SN: return MTLPixelFormatRGBA8Snorm;
            //            case Format::RGB8UI: return MTLPixelFormatRGBA8Uint;
            //            case Format::RGB8I: return MTLPixelFormatRGBA8Sint;
            //            case Format::RGB16F: return MTLPixelFormatRGBA16Float;
            //            case Format::RGB16UI: return MTLPixelFormatRGBA16Uint;
            //            case Format::RGB16I: return MTLPixelFormatRGBA16Sint;
            //            case Format::RGB32F: return MTLPixelFormatRGBA32Float;
            //            case Format::RGB32UI: return MTLPixelFormatRGBA32Uint;
            //            case Format::RGB32I: return MTLPixelFormatRGBA32Sint;

        case Format::RGBA8: return MTLPixelFormatRGBA8Unorm;
        case Format::RGBA8SN: return MTLPixelFormatRGBA8Snorm;
        case Format::RGBA8UI: return MTLPixelFormatRGBA8Uint;
        case Format::RGBA8I: return MTLPixelFormatRGBA8Sint;
        case Format::RGBA16F: return MTLPixelFormatRGBA16Float;
        case Format::RGBA16UI: return MTLPixelFormatRGBA16Uint;
        case Format::RGBA16I: return MTLPixelFormatRGBA16Sint;
        case Format::RGBA32F: return MTLPixelFormatRGBA32Float;
        case Format::RGBA32UI: return MTLPixelFormatRGBA32Uint;
        case Format::RGBA32I: return MTLPixelFormatRGBA32Sint;
        case Format::BGRA8:
            return MTLPixelFormatBGRA8Unorm;

            // Should convert.
            //            case Format::R5G6B5: return MTLPixelFormatB5G6R5Unorm;
            //            case Format::RGB5A1: return MTLPixelFormatBGR5A1Unorm;
            //            case Format::RGBA4: return MTLPixelFormatABGR4Unorm;
            //            case Format::RGB10A2: return MTLPixelFormatBGR10A2Unorm;
        case Format::RGB9E5: return MTLPixelFormatRGB9E5Float;
        case Format::RGB10A2UI: return MTLPixelFormatRGB10A2Uint;
        case Format::R11G11B10F: return MTLPixelFormatRG11B10Float;
        case Format::D16: {
#if (CC_PLATFORM == CC_PLATFORM_MAC_OSX)
            return MTLPixelFormatDepth16Unorm;
#else
            if (@available(iOS 13.0, *))
                return MTLPixelFormatDepth16Unorm;
            else
                break;
#endif
        }
        case Format::D32F: return MTLPixelFormatDepth32Float;
        case Format::D32F_S8: return MTLPixelFormatDepth32Float_Stencil8;
#if (CC_PLATFORM == CC_PLATFORM_MAC_OSX)
        case Format::D24S8: return MTLPixelFormatDepth24Unorm_Stencil8;
        case Format::BC1_ALPHA: return MTLPixelFormatBC1_RGBA;
        case Format::BC1_SRGB_ALPHA: return MTLPixelFormatBC1_RGBA_sRGB;
        case Format::BC2: return MTLPixelFormatBC2_RGBA;
        case Format::BC2_SRGB: return MTLPixelFormatBC2_RGBA_sRGB;
        case Format::BC3: return MTLPixelFormatBC3_RGBA;
        case Format::BC3_SRGB: return MTLPixelFormatBC3_RGBA_sRGB;
#else
        case Format::ASTC_RGBA_4x4: return MTLPixelFormatASTC_4x4_LDR;
        case Format::ASTC_RGBA_5x4: return MTLPixelFormatASTC_5x4_LDR;
        case Format::ASTC_RGBA_5x5: return MTLPixelFormatASTC_5x5_LDR;
        case Format::ASTC_RGBA_6x5: return MTLPixelFormatASTC_6x5_LDR;
        case Format::ASTC_RGBA_6x6: return MTLPixelFormatASTC_6x6_LDR;
        case Format::ASTC_RGBA_8x5: return MTLPixelFormatASTC_8x5_LDR;
        case Format::ASTC_RGBA_8x6: return MTLPixelFormatASTC_8x6_LDR;
        case Format::ASTC_RGBA_8x8: return MTLPixelFormatASTC_8x8_LDR;
        case Format::ASTC_RGBA_10x5: return MTLPixelFormatASTC_10x5_LDR;
        case Format::ASTC_RGBA_10x6: return MTLPixelFormatASTC_10x6_LDR;
        case Format::ASTC_RGBA_10x8: return MTLPixelFormatASTC_10x8_LDR;
        case Format::ASTC_RGBA_10x10: return MTLPixelFormatASTC_10x10_LDR;
        case Format::ASTC_RGBA_12x10: return MTLPixelFormatASTC_12x10_LDR;
        case Format::ASTC_RGBA_12x12: return MTLPixelFormatASTC_12x12_LDR;

        case Format::ASTC_SRGBA_4x4: return MTLPixelFormatASTC_4x4_sRGB;
        case Format::ASTC_SRGBA_5x4: return MTLPixelFormatASTC_5x4_sRGB;
        case Format::ASTC_SRGBA_5x5: return MTLPixelFormatASTC_5x5_sRGB;
        case Format::ASTC_SRGBA_6x5: return MTLPixelFormatASTC_6x5_sRGB;
        case Format::ASTC_SRGBA_6x6: return MTLPixelFormatASTC_6x6_sRGB;
        case Format::ASTC_SRGBA_8x5: return MTLPixelFormatASTC_8x5_sRGB;
        case Format::ASTC_SRGBA_8x6: return MTLPixelFormatASTC_8x6_sRGB;
        case Format::ASTC_SRGBA_8x8: return MTLPixelFormatASTC_8x8_sRGB;
        case Format::ASTC_SRGBA_10x5: return MTLPixelFormatASTC_10x5_sRGB;
        case Format::ASTC_SRGBA_10x6: return MTLPixelFormatASTC_10x6_sRGB;
        case Format::ASTC_SRGBA_10x8: return MTLPixelFormatASTC_10x8_sRGB;
        case Format::ASTC_SRGBA_10x10: return MTLPixelFormatASTC_10x10_sRGB;
        case Format::ASTC_SRGBA_12x10: return MTLPixelFormatASTC_12x10_sRGB;
        case Format::ASTC_SRGBA_12x12: return MTLPixelFormatASTC_12x12_sRGB;

        case Format::ETC2_RGB8: return MTLPixelFormatETC2_RGB8;
        case Format::ETC2_SRGB8: return MTLPixelFormatETC2_RGB8_sRGB;
        case Format::ETC2_RGB8_A1: return MTLPixelFormatETC2_RGB8A1;
        case Format::ETC2_SRGB8_A1: return MTLPixelFormatETC2_RGB8A1_sRGB;
        case Format::ETC2_RGBA8: return MTLPixelFormatEAC_RGBA8;
        case Format::ETC2_SRGB8_A8: return MTLPixelFormatEAC_RGBA8_sRGB;

        case Format::EAC_R11: return MTLPixelFormatEAC_R11Unorm;
        case Format::EAC_R11SN: return MTLPixelFormatEAC_R11Snorm;
        case Format::EAC_RG11: return MTLPixelFormatEAC_RG11Unorm;
        case Format::EAC_RG11SN: return MTLPixelFormatEAC_RG11Snorm;

        case Format::PVRTC_RGB2: return MTLPixelFormatPVRTC_RGB_2BPP;
        case Format::PVRTC_RGBA2: return MTLPixelFormatPVRTC_RGBA_2BPP;
        case Format::PVRTC_RGB4: return MTLPixelFormatPVRTC_RGB_4BPP;
        case Format::PVRTC_RGBA4: return MTLPixelFormatPVRTC_RGBA_4BPP;
#endif
        default: break;
    }
    CC_LOG_ERROR("Invalid pixel format %u", format);
    return MTLPixelFormatInvalid;
}

MTLColorWriteMask toMTLColorWriteMask(ColorMask mask) {
    switch (mask) {
        case ColorMask::R: return MTLColorWriteMaskRed;
        case ColorMask::G: return MTLColorWriteMaskGreen;
        case ColorMask::B: return MTLColorWriteMaskBlue;
        case ColorMask::A: return MTLColorWriteMaskAlpha;
        case ColorMask::ALL: return MTLColorWriteMaskAll;
        default: return MTLColorWriteMaskNone;
    }
}

MTLBlendFactor toMTLBlendFactor(BlendFactor factor) {
    switch (factor) {
        case BlendFactor::ZERO: return MTLBlendFactorZero;
        case BlendFactor::ONE: return MTLBlendFactorOne;
        case BlendFactor::SRC_ALPHA: return MTLBlendFactorSourceAlpha;
        case BlendFactor::DST_ALPHA: return MTLBlendFactorDestinationAlpha;
        case BlendFactor::ONE_MINUS_SRC_ALPHA: return MTLBlendFactorOneMinusSourceAlpha;
        case BlendFactor::ONE_MINUS_DST_ALPHA: return MTLBlendFactorOneMinusDestinationAlpha;
        case BlendFactor::SRC_COLOR: return MTLBlendFactorSourceColor;
        case BlendFactor::DST_COLOR: return MTLBlendFactorDestinationColor;
        case BlendFactor::ONE_MINUS_SRC_COLOR: return MTLBlendFactorOneMinusSourceColor;
        case BlendFactor::ONE_MINUS_DST_COLOR: return MTLBlendFactorOneMinusDestinationColor;
        case BlendFactor::SRC_ALPHA_SATURATE: return MTLBlendFactorSourceAlphaSaturated;
        default: {
            CC_LOG_ERROR("Unsupported blend factor %u", (uint)factor);
            return MTLBlendFactorZero;
        }
    }
}

MTLBlendOperation toMTLBlendOperation(BlendOp op) {
    switch (op) {
        case BlendOp::ADD: return MTLBlendOperationAdd;
        case BlendOp::SUB: return MTLBlendOperationSubtract;
        case BlendOp::REV_SUB: return MTLBlendOperationReverseSubtract;
        case BlendOp::MIN: return MTLBlendOperationMin;
        case BlendOp::MAX: return MTLBlendOperationMax;
    }
}

MTLCullMode toMTLCullMode(CullMode mode) {
    switch (mode) {
        case CullMode::FRONT: return MTLCullModeFront;
        case CullMode::BACK: return MTLCullModeBack;
        case CullMode::NONE: return MTLCullModeNone;
    }
}

MTLWinding toMTLWinding(bool isFrontFaceCCW) {
    if (isFrontFaceCCW)
        return MTLWindingCounterClockwise;
    else
        return MTLWindingClockwise;
}

MTLViewport toMTLViewport(const Viewport &viewport) {
    MTLViewport mtlViewport;
    mtlViewport.originX = viewport.left;
    mtlViewport.originY = viewport.top;
    mtlViewport.width = viewport.width;
    mtlViewport.height = viewport.height;
    mtlViewport.znear = viewport.minDepth;
    mtlViewport.zfar = viewport.maxDepth;

    return mtlViewport;
}

MTLScissorRect toMTLScissorRect(const Rect &rect) {
    MTLScissorRect scissorRect;
    scissorRect.x = rect.x;
    scissorRect.y = rect.y;
    scissorRect.width = rect.width;
    scissorRect.height = rect.height;

    return scissorRect;
}

MTLTriangleFillMode toMTLTriangleFillMode(PolygonMode mode) {
    switch (mode) {
        case PolygonMode::FILL: return MTLTriangleFillModeFill;
        case PolygonMode::LINE: return MTLTriangleFillModeLines;
        case PolygonMode::POINT: {
            CC_LOG_WARNING("Metal doesn't support PolygonMode::POINT, translate to PolygonMode::LINE.");
            return MTLTriangleFillModeLines;
        }
    }
}

MTLDepthClipMode toMTLDepthClipMode(bool isClip) {
    if (isClip)
        return MTLDepthClipModeClip;
    else
        return MTLDepthClipModeClamp;
}

MTLCompareFunction toMTLCompareFunction(ComparisonFunc func) {
    switch (func) {
        case ComparisonFunc::NEVER: return MTLCompareFunctionNever;
        case ComparisonFunc::LESS: return MTLCompareFunctionLess;
        case ComparisonFunc::EQUAL: return MTLCompareFunctionEqual;
        case ComparisonFunc::LESS_EQUAL: return MTLCompareFunctionLessEqual;
        case ComparisonFunc::GREATER: return MTLCompareFunctionGreater;
        case ComparisonFunc::NOT_EQUAL: return MTLCompareFunctionNotEqual;
        case ComparisonFunc::GREATER_EQUAL: return MTLCompareFunctionGreaterEqual;
        case ComparisonFunc::ALWAYS: return MTLCompareFunctionAlways;
    }
}

MTLStencilOperation toMTLStencilOperation(StencilOp op) {
    switch (op) {
        case StencilOp::ZERO: return MTLStencilOperationZero;
        case StencilOp::KEEP: return MTLStencilOperationKeep;
        case StencilOp::REPLACE: return MTLStencilOperationReplace;
        case StencilOp::INCR: return MTLStencilOperationIncrementClamp;
        case StencilOp::DECR: return MTLStencilOperationDecrementClamp;
        case StencilOp::INVERT: return MTLStencilOperationInvert;
        case StencilOp::INCR_WRAP: return MTLStencilOperationIncrementWrap;
        case StencilOp::DECR_WRAP: return MTLStencilOperationDecrementWrap;
    }
}

MTLPrimitiveType toMTLPrimitiveType(PrimitiveMode mode) {
    switch (mode) {
        case PrimitiveMode::POINT_LIST: return MTLPrimitiveTypePoint;
        case PrimitiveMode::LINE_LIST: return MTLPrimitiveTypeLine;
        case PrimitiveMode::LINE_STRIP: return MTLPrimitiveTypeLineStrip;
        case PrimitiveMode::TRIANGLE_LIST: return MTLPrimitiveTypeTriangle;
        case PrimitiveMode::TRIANGLE_STRIP: return MTLPrimitiveTypeTriangleStrip;

        case PrimitiveMode::LINE_LOOP: {
            CC_LOG_ERROR("Metal doesn't support PrimitiveMode::LINE_LOOP. Translate to PrimitiveMode::LINE_LIST.");
            return MTLPrimitiveTypeLine;
        }
        default: {
            //TODO: how to support these mode?
            CC_ASSERT(false);
            return MTLPrimitiveTypeTriangle;
        }
    }
}

MTLTextureUsage toMTLTextureUsage(TextureUsage usage) {
    if (usage == TextureUsage::NONE)
        return MTLTextureUsageUnknown;

    MTLTextureUsage ret = MTLTextureUsageUnknown;
    if (usage & TextureUsage::TRANSFER_SRC)
        ret |= MTLTextureUsageShaderRead;
    if (usage & TextureUsage::TRANSFER_DST)
        ret |= MTLTextureUsageShaderWrite;
    if (usage & TextureUsage::SAMPLED)
        ret |= MTLTextureUsageShaderRead;
    if (usage & TextureUsage::STORAGE)
        ret |= MTLTextureUsageShaderWrite;
    if (usage & TextureUsage::COLOR_ATTACHMENT ||
        usage & TextureUsage::DEPTH_STENCIL_ATTACHMENT ||
        usage & TextureUsage::TRANSIENT_ATTACHMENT ||
        usage & TextureUsage::INPUT_ATTACHMENT) {
        ret |= MTLTextureUsageRenderTarget;
    }

    return ret;
}

MTLTextureType toMTLTextureType(TextureType type) {
    switch (type) {
        case TextureType::TEX1D: return MTLTextureType1D;
        case TextureType::TEX2D: return MTLTextureType2D;
        case TextureType::TEX3D: return MTLTextureType3D;
        case TextureType::CUBE: return MTLTextureTypeCube;
        case TextureType::TEX1D_ARRAY: return MTLTextureType1DArray;
        case TextureType::TEX2D_ARRAY: return MTLTextureType2DArray;
    }
}

NSUInteger toMTLSampleCount(SampleCount count) {
    switch (count) {
        case SampleCount::X1: return 1;
        case SampleCount::X2: return 2;
        case SampleCount::X4: return 4;
        case SampleCount::X8: return 8;
        case SampleCount::X16: return 16;
        case SampleCount::X32: return 32;
        case SampleCount::X64: return 64;
    }
}

MTLSamplerAddressMode toMTLSamplerAddressMode(Address mode) {
    switch (mode) {
        case Address::WRAP: return MTLSamplerAddressModeRepeat;
        case Address::MIRROR: return MTLSamplerAddressModeMirrorRepeat;
        case Address::CLAMP: return MTLSamplerAddressModeClampToEdge;
        case Address::BORDER: {
#if (CC_PLATFORM == CC_PLATFORM_MAC_OSX)
            return MTLSamplerAddressModeClampToBorderColor;
#endif
        }
        default: break;
    }
    CC_LOG_ERROR("Invalid sampler address mode %d, use Address::CLAMP.", mode);
    return MTLSamplerAddressModeClampToEdge;
}

int toMTLSamplerBorderColor(const Color &color) {
#if (CC_PLATFORM == CC_PLATFORM_MAC_OSX)
    float diff = color.x - 0.5f;
    if (math::IsEqualF(color.w, 0.f))
        return MTLSamplerBorderColorTransparentBlack;
    else if (math::IsEqualF(diff, 0.f))
        return MTLSamplerBorderColorOpaqueBlack;
    else
        return MTLSamplerBorderColorOpaqueWhite;
#endif
}

MTLSamplerMinMagFilter toMTLSamplerMinMagFilter(Filter filter) {
    switch (filter) {
        case Filter::LINEAR:
        case Filter::ANISOTROPIC:
            return MTLSamplerMinMagFilterLinear;
        default:
            return MTLSamplerMinMagFilterNearest;
    }
}

MTLSamplerMipFilter toMTLSamplerMipFilter(Filter filter) {
    switch (filter) {
        case Filter::NONE: return MTLSamplerMipFilterNotMipmapped;
        case Filter::LINEAR:
        case Filter::ANISOTROPIC:
            return MTLSamplerMipFilterLinear;
        case Filter::POINT: return MTLSamplerMipFilterNearest;
    }
}

String compileGLSLShader2Msl(const String &src,
                             ShaderStageFlagBit shaderType,
                             Device *device,
                             CCMTLGPUShader *gpuShader) {
#if CC_USE_METAL
    String shaderSource("#version 310 es\n");
    shaderSource.append(src);
    const auto &spv = GLSL2SPIRV(shaderType, shaderSource);
    if (spv.size() == 0)
        return "";

    spirv_cross::CompilerMSL msl(std::move(spv));

    // The SPIR-V is now parsed, and we can perform reflection on it.
    auto executionModel = msl.get_execution_model();
    spirv_cross::MSLResourceBinding newBinding;
    newBinding.stage = executionModel;
    auto active = msl.get_active_interface_variables();
    spirv_cross::ShaderResources resources = msl.get_shader_resources(active);
    msl.set_enabled_interface_variables(std::move(active));

    // Get all uniform buffers in the shader.
    uint maxBufferBindingIndex = static_cast<CCMTLDevice *>(device)->getMaximumBufferBindingIndex();
    const auto &bufferBingdingOffset = device->bindingMappingInfo().bufferOffsets;
    for (const auto &ubo : resources.uniform_buffers) {
        auto set = msl.get_decoration(ubo.id, spv::DecorationDescriptorSet);
        auto binding = msl.get_decoration(ubo.id, spv::DecorationBinding);
        auto size = msl.get_declared_struct_size(msl.get_type(ubo.base_type_id));

        if (binding >= maxBufferBindingIndex) {
            CC_LOG_ERROR("Implemention limits: %s binding at %d, should not use more than %d entries in the buffer argument table", ubo.name.c_str(), binding, maxBufferBindingIndex);
        }
        auto mappedBinding = binding + bufferBingdingOffset[set];
        newBinding.desc_set = set;
        newBinding.binding = binding;
        newBinding.msl_buffer = mappedBinding;
        newBinding.msl_texture = 0;
        newBinding.msl_sampler = 0;
        msl.add_msl_resource_binding(newBinding);

        if (gpuShader->blocks.find(mappedBinding) == gpuShader->blocks.end())
            gpuShader->blocks[mappedBinding] = {ubo.name, set, binding, mappedBinding, shaderType, size};
        else {
            gpuShader->blocks[mappedBinding].stages |= shaderType;
        }
    }

    //TODO: coulsonwang, need to set sampler binding explicitly
    if (resources.sampled_images.size() > static_cast<CCMTLDevice *>(device)->getMaximumSamplerUnits()) {
        CC_LOG_ERROR("Implemention limits: Should not use more than %d entries in the sampler state argument table", static_cast<CCMTLDevice *>(device)->getMaximumSamplerUnits());
        return "";
    }

    // Get all sampled images in the shader.
    unsigned int samplerIndex = 0;
    const auto &samplerBindingOffset = device->bindingMappingInfo().samplerOffsets;
    for (const auto &sampler : resources.sampled_images) {
        auto set = msl.get_decoration(sampler.id, spv::DecorationDescriptorSet);
        auto binding = msl.get_decoration(sampler.id, spv::DecorationBinding);
        int size = 1, s = -1;
        const spirv_cross::SPIRType &type = msl.get_type(sampler.type_id);
        if (type.array_size_literal[0])
        {
            size = type.array[0];
        }
        
        for (int i = 0; i < size; ++i)
        {
            auto mappedBinding = binding + samplerBindingOffset[set] + i;
            newBinding.desc_set = set;
            newBinding.binding = binding + i;
            newBinding.msl_buffer = 0;
            newBinding.msl_texture = mappedBinding;
            newBinding.msl_sampler = samplerIndex;
            msl.add_msl_resource_binding(newBinding);

            if (gpuShader->samplers.find(mappedBinding) == gpuShader->samplers.end()) {
                gpuShader->samplers[mappedBinding] = {sampler.name, set, binding, mappedBinding, samplerIndex, shaderType};
            } else {
                gpuShader->samplers[mappedBinding].stages |= shaderType;
            }

            samplerIndex++;
        }
    }

    // Set some options.
    spirv_cross::CompilerMSL::Options options;
    options.set_msl_version(2, 0);
    #if (CC_PLATFORM == CC_PLATFORM_MAC_IOS)
    options.platform = spirv_cross::CompilerMSL::Options::Platform::iOS;
    #else
    options.platform = spirv_cross::CompilerMSL::Options::Platform::macOS;
    #endif
    msl.set_msl_options(options);

    // Compile to MSL, ready to give to metal driver.
    String output = msl.compile();
    if (!output.size()) {
        CC_LOG_ERROR("Compile to MSL failed.");
        CC_LOG_ERROR("%s", shaderSource.c_str());
    }
    return output;

#else
    return src;
#endif
}

const uint8_t *convertRGB8ToRGBA8(const uint8_t *source, uint length) {
    uint finalLength = length * 4;
    uint8_t *out = (uint8_t *)CC_MALLOC(finalLength);
    if (!out) {
        CC_LOG_WARNING("Failed to alloc memory in convertRGB8ToRGBA8().");
        return source;
    }

    const uint8_t *src = source;
    uint8_t *dst = out;
    for (uint i = 0; i < length; ++i) {
        *dst++ = *src++;
        *dst++ = *src++;
        *dst++ = *src++;
        *dst++ = 255;
    }

    return out;
}

const uint8_t *convertRGB32FToRGBA32F(const uint8_t *source, uint length) {
    uint finalLength = length * sizeof(float) * 4;
    uint8_t *out = (uint8_t *)CC_MALLOC(finalLength);
    if (!out) {
        CC_LOG_WARNING("Failed to alloc memory in convertRGB32FToRGBA32F().");
        return source;
    }

    const float *src = reinterpret_cast<const float *>(source);
    float *dst = reinterpret_cast<float *>(out);
    for (uint i = 0; i < length; ++i) {
        *dst++ = *src++;
        *dst++ = *src++;
        *dst++ = *src++;
        *dst++ = 1.0f;
    }

    return out;
}

NSUInteger highestSupportedFeatureSet(id<MTLDevice> device) {
    NSUInteger maxKnownFeatureSet;
    NSUInteger defaultFeatureSet;
#if CC_PLATFORM == CC_PLATFORM_MAC_IOS
    defaultFeatureSet = MTLFeatureSet_iOS_GPUFamily1_v1;
    if (@available(iOS 12.0, *)) {
        maxKnownFeatureSet = MTLFeatureSet_iOS_GPUFamily4_v2;
    } else if (@available(iOS 11.0, *)) {
        maxKnownFeatureSet = MTLFeatureSet_iOS_GPUFamily4_v1;
    } else if (@available(iOS 10.0, *)) {
        maxKnownFeatureSet = MTLFeatureSet_iOS_GPUFamily3_v2;
    } else if (@available(iOS 9.0, *)) {
        maxKnownFeatureSet = MTLFeatureSet_iOS_GPUFamily3_v1;
    } else {
        maxKnownFeatureSet = MTLFeatureSet_iOS_GPUFamily2_v1;
    }
#else
    defaultFeatureSet = MTLFeatureSet_macOS_GPUFamily1_v1;
    if (@available(macOS 10.14, *)) {
        maxKnownFeatureSet = MTLFeatureSet_macOS_GPUFamily2_v1;
    } else if (@available(macOS 10.13, *)) {
        maxKnownFeatureSet = MTLFeatureSet_macOS_GPUFamily1_v3;
    } else if (@available(macOS 10.12, *)) {
        maxKnownFeatureSet = MTLFeatureSet_macOS_GPUFamily1_v2;
    } else {
        maxKnownFeatureSet = MTLFeatureSet_macOS_GPUFamily1_v1;
    }
#endif
    for (int featureSet = maxKnownFeatureSet; featureSet >= 0; --featureSet) {
        if ([device supportsFeatureSet:MTLFeatureSet(featureSet)]) {
            return featureSet;
        }
    }
    return defaultFeatureSet;
}

#if CC_PLATFORM == CC_PLATFORM_MAC_IOS
String getIOSFeatureSetToString(MTLFeatureSet featureSet) {
    if (@available(iOS 8.0, *)) {
        switch (featureSet) {
            case MTLFeatureSet_iOS_GPUFamily1_v1:
                return "MTLFeatureSet_iOS_GPUFamily1_v1";
            case MTLFeatureSet_iOS_GPUFamily2_v1:
                return "MTLFeatureSet_iOS_GPUFamily2_v1";
            default:
                break;
        }
    }
    if (@available(iOS 9.0, *)) {
        switch (featureSet) {
            case MTLFeatureSet_iOS_GPUFamily1_v2:
                return "MTLFeatureSet_iOS_GPUFamily1_v2";
            case MTLFeatureSet_iOS_GPUFamily2_v2:
                return "MTLFeatureSet_iOS_GPUFamily2_v2";
            case MTLFeatureSet_iOS_GPUFamily3_v1:
                return "MTLFeatureSet_iOS_GPUFamily3_v1";
            default:
                break;
        }
    }
    if (@available(iOS 10.0, *)) {
        switch (featureSet) {
            case MTLFeatureSet_iOS_GPUFamily1_v3:
                return "MTLFeatureSet_iOS_GPUFamily1_v3";
            case MTLFeatureSet_iOS_GPUFamily2_v3:
                return "MTLFeatureSet_iOS_GPUFamily2_v3";
            case MTLFeatureSet_iOS_GPUFamily3_v2:
                return "MTLFeatureSet_iOS_GPUFamily3_v2";
            default:
                break;
        }
    }
    if (@available(iOS 11.0, *)) {
        switch (featureSet) {
            case MTLFeatureSet_iOS_GPUFamily1_v4:
                return "MTLFeatureSet_iOS_GPUFamily2_v4";
            case MTLFeatureSet_iOS_GPUFamily2_v3:
                return "MTLFeatureSet_iOS_GPUFamily2_v3";
            case MTLFeatureSet_iOS_GPUFamily3_v3:
                return "MTLFeatureSet_iOS_GPUFamily3_v3";
            case MTLFeatureSet_iOS_GPUFamily4_v1:
                return "MTLFeatureSet_iOS_GPUFamily4_v1";
            default:
                break;
        }
    }
    if (@available(iOS 12.0, *)) {
        switch (featureSet) {
            case MTLFeatureSet_iOS_GPUFamily1_v5:
                return "MTLFeatureSet_iOS_GPUFamily1_v5";
            case MTLFeatureSet_iOS_GPUFamily2_v5:
                return "MTLFeatureSet_iOS_GPUFamily2_v5";
            case MTLFeatureSet_iOS_GPUFamily3_v4:
                return "MTLFeatureSet_iOS_GPUFamily3_v4";
            case MTLFeatureSet_iOS_GPUFamily4_v2:
                return "MTLFeatureSet_iOS_GPUFamily4_v2";
            default:
                break;
        }
    }
    return "Invalid metal feature set";
}

GPUFamily getIOSGPUFamily(MTLFeatureSet featureSet) {
    if (@available(iOS 12.0, *)) {
        switch (featureSet) {
            case MTLFeatureSet_iOS_GPUFamily1_v5:
                return GPUFamily::Apple1;
            case MTLFeatureSet_iOS_GPUFamily2_v5:
                return GPUFamily::Apple2;
            case MTLFeatureSet_iOS_GPUFamily3_v4:
                return GPUFamily::Apple3;
            case MTLFeatureSet_iOS_GPUFamily4_v2:
                return GPUFamily::Apple4;
            default:
                break;
        }
    }
    if (@available(iOS 11.0, *)) {
        switch (featureSet) {
            case MTLFeatureSet_iOS_GPUFamily1_v4:
                return GPUFamily::Apple1;
            case MTLFeatureSet_iOS_GPUFamily2_v4:
                return GPUFamily::Apple2;
            case MTLFeatureSet_iOS_GPUFamily3_v3:
                return GPUFamily::Apple3;
            case MTLFeatureSet_iOS_GPUFamily4_v1:
                return GPUFamily::Apple4;
            default:
                break;
        }
    }
    if (@available(iOS 10.0, *)) {
        switch (featureSet) {
            case MTLFeatureSet_iOS_GPUFamily1_v3:
                return GPUFamily::Apple1;
            case MTLFeatureSet_iOS_GPUFamily2_v3:
                return GPUFamily::Apple2;
            case MTLFeatureSet_iOS_GPUFamily3_v2:
                return GPUFamily::Apple3;
            default:
                break;
        }
    }
    if (@available(iOS 9.0, *)) {
        switch (featureSet) {
            case MTLFeatureSet_iOS_GPUFamily1_v2:
                return GPUFamily::Apple1;
            case MTLFeatureSet_iOS_GPUFamily2_v2:
                return GPUFamily::Apple2;
            case MTLFeatureSet_iOS_GPUFamily3_v1:
                return GPUFamily::Apple3;
            default:
                break;
        }
    }
    if (@available(iOS 8.0, *)) {
        switch (featureSet) {
            case MTLFeatureSet_iOS_GPUFamily1_v1:
                return GPUFamily::Apple1;
            case MTLFeatureSet_iOS_GPUFamily2_v1:
                return GPUFamily::Apple2;
            default:
                break;
        }
    }
    return GPUFamily::Apple1;
}
#else
String getMacFeatureSetToString(MTLFeatureSet featureSet) {
    if (@available(macOS 10.11, *)) {
        switch (featureSet) {
            case MTLFeatureSet_macOS_GPUFamily1_v1:
                return "MTLFeatureSet_macOS_GPUFamily1_v1";
            default:
                break;
        }
    }
    if (@available(macOS 10.12, *)) {
        switch (featureSet) {
            case MTLFeatureSet_macOS_GPUFamily1_v2:
                return "MTLFeatureSet_macOS_GPUFamily1_v2";
            default:
                break;
        }
    }
    if (@available(macOS 10.13, *)) {
        switch (featureSet) {
            case MTLFeatureSet_macOS_GPUFamily1_v3:
                return "MTLFeatureSet_macOS_GPUFamily1_v3";
            default:
                break;
        }
    }
    if (@available(macOS 10.14, *)) {
        switch (featureSet) {
            case MTLFeatureSet_macOS_GPUFamily1_v4:
                return "MTLFeatureSet_macOS_GPUFamily1_v4";
            case MTLFeatureSet_macOS_GPUFamily2_v1:
                return "MTLFeatureSet_macOS_GPUFamily2_v1";
            default:
                break;
        }
    }
    return "Invalid metal feature set";
}

GPUFamily getMacGPUFamily(MTLFeatureSet featureSet) {
    if (@available(macOS 10.14, *)) {
        if (MTLFeatureSet_macOS_GPUFamily2_v1 <= featureSet) {
            return GPUFamily::Mac2;
        }
    }
    return GPUFamily::Mac1;
}
#endif

uint getGPUFamily(MTLFeatureSet featureSet) {
#if CC_PLATFORM == CC_PLATFORM_MAC_IOS
    return static_cast<uint>(getIOSGPUFamily(featureSet));
#else
    return static_cast<uint>(getMacGPUFamily(featureSet));
#endif
}

uint getMaxVertexAttributes(uint family) {
    switch (static_cast<GPUFamily>(family)) {
        case GPUFamily::Apple1:
        case GPUFamily::Apple2:
        case GPUFamily::Apple3:
        case GPUFamily::Apple4:
        case GPUFamily::Apple5:
        case GPUFamily::Apple6:
        case GPUFamily::Mac1:
        case GPUFamily::Mac2:
            return 31;
        default:
            return 31;
    }
}

uint getMaxEntriesInBufferArgumentTable(uint family) {
    switch (static_cast<GPUFamily>(family)) {
        case GPUFamily::Apple1:
        case GPUFamily::Apple2:
        case GPUFamily::Apple3:
        case GPUFamily::Apple4:
        case GPUFamily::Apple5:
        case GPUFamily::Apple6:
        case GPUFamily::Mac1:
        case GPUFamily::Mac2:
            return 31;
        default:
            return 31;
    }
}

uint getMaxEntriesInTextureArgumentTable(uint family) {
    switch (static_cast<GPUFamily>(family)) {
        case GPUFamily::Apple1:
        case GPUFamily::Apple2:
        case GPUFamily::Apple3:
            return 31;
        case GPUFamily::Apple4:
        case GPUFamily::Apple5:
            return 96;
        case GPUFamily::Apple6:
        case GPUFamily::Mac1:
        case GPUFamily::Mac2:
            return 128;
        default:
            return 31;
    }
}

uint getMaxEntriesInSamplerStateArgumentTable(uint family) {
    switch (static_cast<GPUFamily>(family)) {
        case GPUFamily::Apple1:
        case GPUFamily::Apple2:
        case GPUFamily::Apple3:
        case GPUFamily::Apple4:
        case GPUFamily::Apple5:
        case GPUFamily::Apple6:
        case GPUFamily::Mac1:
        case GPUFamily::Mac2:
            return 16;
        default:
            return 16;
    }
}

uint getMaxTexture2DWidthHeight(uint family) {
    switch (static_cast<GPUFamily>(family)) {
        case GPUFamily::Apple1:
        case GPUFamily::Apple2:
            return 8192;
        case GPUFamily::Apple3:
        case GPUFamily::Apple4:
        case GPUFamily::Apple5:
        case GPUFamily::Apple6:
        case GPUFamily::Mac1:
        case GPUFamily::Mac2:
            return 16384;
        default:
            return 8192;
    }
}

uint getMaxCubeMapTextureWidthHeight(uint family) {
    switch (static_cast<GPUFamily>(family)) {
        case GPUFamily::Apple1:
        case GPUFamily::Apple2:
            return 8192;
        case GPUFamily::Apple3:
        case GPUFamily::Apple4:
        case GPUFamily::Apple5:
        case GPUFamily::Apple6:
        case GPUFamily::Mac1:
        case GPUFamily::Mac2:
            return 16384;
        default:
            return 8192;
    }
}

uint getMaxColorRenderTarget(uint family) {
    switch (static_cast<GPUFamily>(family)) {
        case GPUFamily::Apple1:
            return 4;
        case GPUFamily::Apple2:
        case GPUFamily::Apple3:
        case GPUFamily::Apple4:
        case GPUFamily::Apple5:
        case GPUFamily::Apple6:
        case GPUFamily::Mac1:
        case GPUFamily::Mac2:
            return 8;
        default:
            return 4;
    }
}

uint getMinBufferOffsetAlignment(uint family) {
    switch (static_cast<GPUFamily>(family)) {
        case GPUFamily::Apple1:
        case GPUFamily::Apple2:
        case GPUFamily::Apple3:
        case GPUFamily::Apple4:
        case GPUFamily::Apple5:
        case GPUFamily::Apple6:
#ifdef TARGET_OS_SIMULATOR
            return 256;
#else
            return 4; //4 Bytes
#endif
        case GPUFamily::Mac1:
        case GPUFamily::Mac2:
            return 256; //256 Bytes
        default:
            return 1;
    }
}

bool isPVRTCSuppported(uint family) {
    switch (static_cast<GPUFamily>(family)) {
        case GPUFamily::Apple1:
        case GPUFamily::Apple2:
        case GPUFamily::Apple3:
        case GPUFamily::Apple4:
        case GPUFamily::Apple5:
        case GPUFamily::Apple6:
            return true;
        case GPUFamily::Mac1:
        case GPUFamily::Mac2:
            return false;
        default:
            return false;
    }
}

bool isEAC_ETCCSuppported(uint family) {
    switch (static_cast<GPUFamily>(family)) {
        case GPUFamily::Apple1:
        case GPUFamily::Apple2:
        case GPUFamily::Apple3:
        case GPUFamily::Apple4:
        case GPUFamily::Apple5:
        case GPUFamily::Apple6:
            return true;
        case GPUFamily::Mac1:
        case GPUFamily::Mac2:
            return false;
        default:
            return false;
    }
}

bool isASTCSuppported(uint family) {
    switch (static_cast<GPUFamily>(family)) {
        case GPUFamily::Apple1:
            return false;
        case GPUFamily::Apple2:
        case GPUFamily::Apple3:
        case GPUFamily::Apple4:
        case GPUFamily::Apple5:
        case GPUFamily::Apple6:
            return true;
        case GPUFamily::Mac1:
        case GPUFamily::Mac2:
            return false;
        default:
            return false;
    }
}

bool isBCSupported(uint family) {
    switch (static_cast<GPUFamily>(family)) {
        case GPUFamily::Apple1:
        case GPUFamily::Apple2:
        case GPUFamily::Apple3:
        case GPUFamily::Apple4:
        case GPUFamily::Apple5:
        case GPUFamily::Apple6:
            return false;
        case GPUFamily::Mac1:
        case GPUFamily::Mac2:
            return true;
        default:
            return false;
    }
}

bool isColorBufferFloatSupported(uint family) {
    switch (static_cast<GPUFamily>(family)) {
        case GPUFamily::Apple1:
        case GPUFamily::Apple2:
        case GPUFamily::Apple3:
        case GPUFamily::Apple4:
        case GPUFamily::Apple5:
        case GPUFamily::Apple6:
        case GPUFamily::Mac1:
        case GPUFamily::Mac2:
            return true;
        default:
            return false;
    }
}

bool isColorBufferHalfFloatSupported(uint family) {
    switch (static_cast<GPUFamily>(family)) {
        case GPUFamily::Apple1:
        case GPUFamily::Apple2:
        case GPUFamily::Apple3:
        case GPUFamily::Apple4:
        case GPUFamily::Apple5:
        case GPUFamily::Apple6:
        case GPUFamily::Mac1:
        case GPUFamily::Mac2:
            return true;
        default:
            return false;
    }
}

bool isLinearTextureSupported(uint family) {
    switch (static_cast<GPUFamily>(family)) {
        case GPUFamily::Apple1:
        case GPUFamily::Apple2:
        case GPUFamily::Apple3:
        case GPUFamily::Apple4:
        case GPUFamily::Apple5:
        case GPUFamily::Apple6:
        case GPUFamily::Mac1:
        case GPUFamily::Mac2:
            return true;
        default:
            return false;
    }
}

bool isIndirectCommandBufferSupported(MTLFeatureSet featureSet) {
#if CC_PLATFORM == CC_PLATFORM_MAC_IOS
    if (@available(iOS 12.0, *)) {
        return featureSet >= MTLFeatureSet_iOS_GPUFamily3_v4;
    }
#else
    if (@available(macOS 10.14, *)) {
        return featureSet >= MTLFeatureSet_macOS_GPUFamily2_v1;
    }
#endif
    return false;
}
bool isDepthStencilFormatSupported(id<MTLDevice> device, Format format, uint family) {
    GPUFamily gpuFamily = static_cast<GPUFamily>(family);
    switch (format) {
        case Format::D16:
            switch (gpuFamily) {
                case GPUFamily::Apple1:
                case GPUFamily::Apple2:
                case GPUFamily::Apple3:
                case GPUFamily::Apple4:
                case GPUFamily::Apple5:
                case GPUFamily::Apple6:
                case GPUFamily::Mac1:
                case GPUFamily::Mac2:
                    return true;
                default:
                    return false;
            }
        case Format::D32F:
        case Format::D32F_S8:
            switch (gpuFamily) {
                case GPUFamily::Apple1:
                case GPUFamily::Apple2:
                case GPUFamily::Apple3:
                case GPUFamily::Apple4:
                case GPUFamily::Apple5:
                case GPUFamily::Apple6:
#ifdef TARGET_OS_SIMULATOR
                    return true;
#else
                    return false;
#endif
                case GPUFamily::Mac1:
                case GPUFamily::Mac2:
                    return true;
                default:
                    return false;
            }
        case Format::D24S8:
#if (CC_PLATFORM == CC_PLATFORM_MAC_OSX)
            return [device isDepth24Stencil8PixelFormatSupported];
#else
            return false;
#endif
        default:
            return false;
    }
}

bool isIndirectDrawSupported(uint family) {
#if CC_PLATFORM == CC_PLATFORM_MAC_IOS
    return static_cast<GPUFamily>(family) < GPUFamily::Apple3 ? false : true; //is only supported on MTLFeatureSet_iOS_GPUFamily3_v1 and later'
#else
    return true;
#endif
}

MTLPixelFormat getSupportedDepthStencilFormat(id<MTLDevice> device, uint family, uint &dephBits) {
    vector<std::tuple<cc::gfx::Format, uint>> formats = {{Format::D24S8, 24}, {Format::D32F_S8, 32}, {Format::D16S8, 16}};
    Format format;
    for (const auto &formatPair : formats) {
        std::tie(format, dephBits) = formatPair;
        if (isDepthStencilFormatSupported(device, format, family))
            return toMTLPixelFormat(format);
        else
            continue;
    }
    return MTLPixelFormatInvalid;
}

String featureSetToString(MTLFeatureSet featureSet) {
#if CC_PLATFORM == CC_PLATFORM_MAC_IOS
    return getIOSFeatureSetToString(featureSet);
#else
    return getMacFeatureSetToString(featureSet);
#endif
}

const uint8_t *const convertData(const uint8_t *source, uint length, Format type) {
    switch (type) {
        case Format::RGB8: return mu::convertRGB8ToRGBA8(source, length);
        case Format::RGB32F: return mu::convertRGB32FToRGBA32F(source, length);
        default: return source;
    }
}

bool isASTCFormat(Format format) {
    switch (format) {
        case Format::ASTC_RGBA_4x4:
        case Format::ASTC_SRGBA_4x4:
        case Format::ASTC_RGBA_5x4:
        case Format::ASTC_SRGBA_5x4:
        case Format::ASTC_RGBA_5x5:
        case Format::ASTC_SRGBA_5x5:
        case Format::ASTC_RGBA_6x5:
        case Format::ASTC_SRGBA_6x5:
        case Format::ASTC_RGBA_6x6:
        case Format::ASTC_SRGBA_6x6:
        case Format::ASTC_RGBA_8x5:
        case Format::ASTC_SRGBA_8x5:
        case Format::ASTC_RGBA_8x6:
        case Format::ASTC_SRGBA_8x6:
        case Format::ASTC_RGBA_8x8:
        case Format::ASTC_SRGBA_8x8:
        case Format::ASTC_RGBA_10x5:
        case Format::ASTC_SRGBA_10x5:
        case Format::ASTC_RGBA_10x6:
        case Format::ASTC_SRGBA_10x6:
        case Format::ASTC_RGBA_10x8:
        case Format::ASTC_SRGBA_10x8:
        case Format::ASTC_RGBA_10x10:
        case Format::ASTC_SRGBA_10x10:
        case Format::ASTC_RGBA_12x10:
        case Format::ASTC_SRGBA_12x10:
        case Format::ASTC_RGBA_12x12:
        case Format::ASTC_SRGBA_12x12:
            return true;
        default:
            return false;
    }
}

uint getBlockSize(Format format) {
    switch (format) {
        case Format::ASTC_RGBA_4x4:
        case Format::ASTC_SRGBA_4x4:
        case Format::ASTC_RGBA_5x4:
        case Format::ASTC_SRGBA_5x4:
        case Format::ASTC_RGBA_5x5:
        case Format::ASTC_SRGBA_5x5:
        case Format::ASTC_RGBA_6x5:
        case Format::ASTC_SRGBA_6x5:
        case Format::ASTC_RGBA_6x6:
        case Format::ASTC_SRGBA_6x6:
        case Format::ASTC_RGBA_8x5:
        case Format::ASTC_SRGBA_8x5:
        case Format::ASTC_RGBA_8x6:
        case Format::ASTC_SRGBA_8x6:
        case Format::ASTC_RGBA_8x8:
        case Format::ASTC_SRGBA_8x8:
        case Format::ASTC_RGBA_10x5:
        case Format::ASTC_SRGBA_10x5:
        case Format::ASTC_RGBA_10x6:
        case Format::ASTC_SRGBA_10x6:
        case Format::ASTC_RGBA_10x8:
        case Format::ASTC_SRGBA_10x8:
        case Format::ASTC_RGBA_10x10:
        case Format::ASTC_SRGBA_10x10:
        case Format::ASTC_RGBA_12x10:
        case Format::ASTC_SRGBA_12x10:
        case Format::ASTC_RGBA_12x12:
        case Format::ASTC_SRGBA_12x12:
            return 16u;
        case Format::PVRTC_RGB2:
        case Format::PVRTC_RGBA2:
            return 32u; // blockWidth = 8, blockHeight = 4, bitsPerPixel = 2;
        case Format::PVRTC_RGB4:
        case Format::PVRTC_RGBA4:
            return 16u; // blockWidth = 4, blockHeight = 4, bitsPerPixel = 4;
        case Format::ETC2_RGB8:
        case Format::ETC2_SRGB8:
        case Format::ETC2_RGB8_A1:
        case Format::ETC2_SRGB8_A1:
        case Format::EAC_R11:
        case Format::EAC_R11SN:
            return 8u; // blockWidth = 4, blockHeight = 4
        case Format::ETC2_RGBA8:
        case Format::ETC2_SRGB8_A8:
        case Format::EAC_RG11:
        case Format::EAC_RG11SN: // blockWidth = 4, blockHeight = 4;
            return 16u;
        default:
            return GFX_FORMAT_INFOS[static_cast<uint>(format)].size;
    }
}

uint getBytesPerRow(Format format, uint width) {
    uint blockSize = getBlockSize(format);
    uint widthInBlock = 1u;
    switch (format) {
        case Format::ASTC_RGBA_4x4:
        case Format::ASTC_SRGBA_4x4:
            widthInBlock = (width + 3) / 4;
            break;
        case Format::ASTC_RGBA_5x4:
        case Format::ASTC_SRGBA_5x4:
        case Format::ASTC_RGBA_5x5:
        case Format::ASTC_SRGBA_5x5:
            widthInBlock = (width + 4) / 5;
            break;
        case Format::ASTC_RGBA_6x5:
        case Format::ASTC_SRGBA_6x5:
        case Format::ASTC_RGBA_6x6:
        case Format::ASTC_SRGBA_6x6:
            widthInBlock = (width + 5) / 6;
            break;
        case Format::ASTC_RGBA_8x5:
        case Format::ASTC_SRGBA_8x5:
        case Format::ASTC_RGBA_8x6:
        case Format::ASTC_SRGBA_8x6:
        case Format::ASTC_RGBA_8x8:
        case Format::ASTC_SRGBA_8x8:
            widthInBlock = (width + 7) / 8;
            break;
        case Format::ASTC_RGBA_10x5:
        case Format::ASTC_SRGBA_10x5:
        case Format::ASTC_RGBA_10x6:
        case Format::ASTC_SRGBA_10x6:
        case Format::ASTC_RGBA_10x8:
        case Format::ASTC_SRGBA_10x8:
        case Format::ASTC_RGBA_10x10:
        case Format::ASTC_SRGBA_10x10:
            widthInBlock = (width + 9) / 10;
            break;
        case Format::ASTC_RGBA_12x10:
        case Format::ASTC_SRGBA_12x10:
        case Format::ASTC_RGBA_12x12:
        case Format::ASTC_SRGBA_12x12:
            widthInBlock = (width + 11) / 12;
            break;
        case Format::PVRTC_RGB2:
        case Format::PVRTC_RGBA2:
            widthInBlock = width / 2;
            break;
        case Format::PVRTC_RGB4:
        case Format::PVRTC_RGBA4:
            widthInBlock = width / 4;
            break;
        case Format::ETC2_RGB8:
        case Format::ETC2_SRGB8:
        case Format::ETC2_RGB8_A1:
        case Format::ETC2_SRGB8_A1:
        case Format::EAC_R11:
        case Format::EAC_R11SN:
        case Format::EAC_RG11:
        case Format::EAC_RG11SN:
        case Format::ETC2_RGBA8:
        case Format::ETC2_SRGB8_A8:
            widthInBlock = width / 4;
            break;
        default:
            widthInBlock = width;
            break;
    }
    return widthInBlock * blockSize;
}

bool pixelFormatIsColorRenderable(Format format) {
    MTLPixelFormat pixelFormat = toMTLPixelFormat(format);
    BOOL isCompressedFormat = false;
#if CC_PLATFORM == CC_PLATFORM_MAC_IOS
    isCompressedFormat = (pixelFormat >= MTLPixelFormatASTC_4x4_sRGB && pixelFormat <= MTLPixelFormatASTC_12x12_LDR) ||
                         (pixelFormat >= MTLPixelFormatPVRTC_RGB_2BPP && pixelFormat <= MTLPixelFormatPVRTC_RGBA_4BPP_sRGB) ||
                         (pixelFormat >= MTLPixelFormatEAC_R11Unorm && pixelFormat <= MTLPixelFormatETC2_RGB8A1_sRGB);
#else
    isCompressedFormat = (pixelFormat >= MTLPixelFormatBC1_RGBA && pixelFormat <= MTLPixelFormatBC3_RGBA_sRGB);
#endif
    BOOL is422Format = (pixelFormat == MTLPixelFormatGBGR422 || pixelFormat == MTLPixelFormatBGRG422);

    return !isCompressedFormat && !is422Format && !(pixelFormat == MTLPixelFormatInvalid);
}

MTLBlitOption getBlitOption(Format format) {
    const MTLPixelFormat pixelFormat = toMTLPixelFormat(format);
#if CC_PLATFORM == CC_PLATFORM_MAC_IOS
    if (pixelFormat >= MTLPixelFormatPVRTC_RGB_2BPP && pixelFormat <= MTLPixelFormatPVRTC_RGBA_4BPP_sRGB) {
        return MTLBlitOptionRowLinearPVRTC;
    }
#endif
    return MTLBlitOptionNone;
}

//CompareFunction of MTLSamplerDescriptor is only supported on MTLFeatureSet_iOS_GPUFamily3_v1 and later
bool isSamplerDescriptorCompareFunctionSupported(uint family) {
#if CC_PLATFORM == CC_PLATFORM_MAC_IOS
    return (static_cast<GPUFamily>(family) < GPUFamily::Apple3) ? false : true;
#else
    return true;
#endif
}

gfx::Shader *createShader(CCMTLDevice *device) {
    String vs = R"(
            layout(location = 0) in vec2 a_position;
            void main() {
                gl_Position = vec4(a_position, 0.0, 1.0);
            }
    )";
    String fs = R"(
            precision mediump float;
            layout(set = 0, binding = 0) uniform Color {
                vec4 u_color;
            };
            layout(location = 0) out vec4 o_color;

            void main() {
                o_color = u_color;
            }
    )";
    gfx::ShaderStageList shaderStageList;
    gfx::ShaderStage vertexShaderStage;
    vertexShaderStage.stage = gfx::ShaderStageFlagBit::VERTEX;
    vertexShaderStage.source = std::move(vs);
    shaderStageList.emplace_back(std::move(vertexShaderStage));

    gfx::ShaderStage fragmentShaderStage;
    fragmentShaderStage.stage = gfx::ShaderStageFlagBit::FRAGMENT;
    fragmentShaderStage.source = std::move(fs);
    shaderStageList.emplace_back(std::move(fragmentShaderStage));

    gfx::UniformBlockList uniformBlockList = {
        {0, 0, "Color", {{"u_color", gfx::Type::FLOAT4, 1}}, 1},
    };
    gfx::AttributeList attributeList = {{"a_position", gfx::Format::RG32F, false, 0, false, 0}};

    gfx::ShaderInfo shaderInfo;
    shaderInfo.name = "Clear Render Area";
    shaderInfo.stages = std::move(shaderStageList);
    shaderInfo.attributes = std::move(attributeList);
    shaderInfo.blocks = std::move(uniformBlockList);
    return device->createShader(shaderInfo);
}

//TODO need release pipelineState
gfx::PipelineState *pipelineState = nullptr;
CCMTLGPUPipelineState *getClearRenderPassPipelineState(CCMTLDevice *device, RenderPass *renderPass) {
    if (pipelineState) return static_cast<CCMTLPipelineState *>(pipelineState)->getGPUPipelineState();

    gfx::Attribute position = {"a_position", gfx::Format::RG32F, false, 0, false};
    gfx::PipelineStateInfo pipelineInfo;
    pipelineInfo.primitive = gfx::PrimitiveMode::TRIANGLE_LIST;
    pipelineInfo.shader = createShader(device);
    pipelineInfo.inputState = {{position}};
    pipelineInfo.renderPass = renderPass;

    pipelineState = device->createPipelineState(std::move(pipelineInfo));
    CC_DELETE(pipelineInfo.shader);
    return static_cast<CCMTLPipelineState *>(pipelineState)->getGPUPipelineState();
}

void clearRenderArea(CCMTLDevice *device, id<MTLCommandBuffer> commandBuffer, RenderPass *renderPass, const Rect &renderArea, const Color *colors, float depth, int stencil) {
    const auto gpuPSO = getClearRenderPassPipelineState(device, renderPass);
    const auto mtlRenderPass = static_cast<CCMTLRenderPass *>(renderPass);
    uint slot = 0u;
    MTLRenderPassDescriptor *renderPassDescriptor = mtlRenderPass->getMTLRenderPassDescriptor();
    const auto &renderTargetSizes = mtlRenderPass->getRenderTargetSizes();
    float renderTargetWidth = renderTargetSizes[slot].x;
    float renderTargetHeight = renderTargetSizes[slot].y;
    float halfWidth = renderTargetWidth * 0.5f;
    float halfHeight = renderTargetHeight * 0.5f;
    float rcpWidth = 1.0f / halfWidth;
    float rcpHeight = 1.0f / halfHeight;
    float width = renderArea.x + renderArea.width;
    float height = renderArea.height + renderArea.y;
    Vec2 leftTop{(renderArea.x - halfWidth) * rcpWidth, (halfHeight - renderArea.y) * rcpHeight};
    Vec2 rightTop{(width - halfWidth) * rcpWidth, (halfHeight - renderArea.y) * rcpHeight};
    Vec2 rightBottom{(width - halfWidth) * rcpWidth, (halfHeight - height) * rcpHeight};
    Vec2 leftBottom{(renderArea.x - halfWidth) * rcpWidth, (halfHeight - height) * rcpHeight};
    Vec2 vertexes[] = {leftTop, leftBottom, rightBottom, leftTop, rightBottom, rightTop};

    bool isClearingColor = false;
    bool isClearingDepth = false;
    bool isClearingStencil = false;
    const auto &colorAttachments = renderPass->getColorAttachments();
    const auto &depthStencilAttachment = renderPass->getDepthStencilAttachment();
    if (colorAttachments.size() && colorAttachments[0].loadOp == LoadOp::CLEAR) {
        isClearingColor = true;
    }
    if (depthStencilAttachment.depthLoadOp == LoadOp::CLEAR) {
        isClearingDepth = true;
    }
    if (depthStencilAttachment.stencilLoadOp == LoadOp::CLEAR) {
        isClearingStencil = true;
    }

    id<MTLRenderCommandEncoder> renderEncoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];
    [renderEncoder setViewport:(MTLViewport){0, 0, renderTargetWidth, renderTargetHeight}];
    [renderEncoder setScissorRect:(MTLScissorRect){0, 0, static_cast<uint>(renderTargetWidth), static_cast<uint>(renderTargetHeight)}];
    [renderEncoder setRenderPipelineState:gpuPSO->mtlRenderPipelineState];
    if (gpuPSO->mtlDepthStencilState) {
        [renderEncoder setStencilFrontReferenceValue:gpuPSO->stencilRefFront
                                  backReferenceValue:gpuPSO->stencilRefBack];
        [renderEncoder setDepthStencilState:gpuPSO->mtlDepthStencilState];
    }

    [renderEncoder setVertexBytes:vertexes
                           length:sizeof(vertexes)
                          atIndex:30];

    [renderEncoder setFragmentBytes:&colors[slot]
                             length:sizeof(colors[slot])
                            atIndex:0];

    uint count = sizeof(vertexes) / sizeof(Vec2);
    [renderEncoder drawPrimitives:MTLPrimitiveTypeTriangle
                      vertexStart:0
                      vertexCount:count];

    [renderEncoder endEncoding];
    renderPassDescriptor.colorAttachments[slot].loadAction = MTLLoadActionLoad;
}

} //namespace mu

} // namespace gfx
} // namespace cc
