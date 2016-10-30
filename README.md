teleport
=====

Teleport is a replacement for native Erlang RPC. 

It's main usage right now is in openkvs and barrel.


### WIP 

Bare in mind that the API is a WIP and will likely change before 1.0. This is only used on 
purpose inside the barrel project and not yet supported for external usages.

For example things that are expected to change are the following:

- routing configuration . for now the routing and dispatching is quite primitive and 
need to be extended to handle true roundrobin and groups 
- message dispatching. For now we mimic the RPC api, but we may need something more dynamic

Also the plugin api is not implemented. 

Build
-----

    $ rebar3 compile
