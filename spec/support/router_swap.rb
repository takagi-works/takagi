# frozen_string_literal: true

# Row 23 of .omo/plans/coap-proxy.md: the proxy specs point the GLOBAL middleware stack at a
# throwaway router while an example runs. The mutation lives here so the restore happens in an
# `ensure` - a throwaway router can never be left installed on `MiddlewareStack.instance`, however
# the example or its hooks end. It also gives the swap one home instead of eight copies of the
# `instance_variable_set` + `after` pair (whose restore relied on RSpec having run the `after`).
module RouterSwap
  # Points `MiddlewareStack.instance` at `router` for the duration of the block, restoring the
  # router that was installed before it - on the normal path and on any raise.
  def with_router(router)
    stack = Takagi::MiddlewareStack.instance
    previous = stack.router
    stack.router = router
    yield
  ensure
    stack.router = previous
  end
end

RSpec.configure do |config|
  config.include(RouterSwap)
end
