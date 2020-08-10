#pragma once

#include "../RenderFlow.h"

namespace cc {
namespace pipeline {

class RenderView;
class ForwardStage;

class ForwardFlow : public RenderFlow {
public:
    ForwardFlow() = default;
    virtual ~ForwardFlow();

    static const RenderFlowInfo &getInitializeInfo();

    virtual bool initialize(const RenderFlowInfo &info) override;
    virtual void destroy() override;
    virtual void render(RenderView *view) override;

private:
    static RenderFlowInfo _initInfo;

    ForwardStage *_forwardStage = nullptr;
};

} // namespace pipeline
} // namespace cc
