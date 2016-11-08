teleport
=====

Teleport is a replacement for native Erlang RPC. It create direct links between servers.

It's main usage right now is in openkvs and barrel.

Basic Usage
-----

#### 1) Start a server

```erlang
2> teleport:start_server(test, []).
21:31:49.065 [info] teleport: start server: link://enlil-2:60736
{ok,<0.256.0>}
3> teleport:server_uri(test).
"link://enlil-2:60736"
```

Notice the link created, that can be reused later in the client

#### 2) Connect a node to it

```erlang
2> teleport:connect(test, "link://enlil-2:60736").
true
21:35:46.631 [info] teleport: client connected to peer-node test['test@enlil-2:60736']

3> teleport:call(test, erlang, node, []).
'test0@enlil-2'
```

Sub Channels
-----

teleport allows you to create sub channels over a connections and remote subscriptions.

1) On a teleport server, register a process:

```erlang
2>  teleport:start_server(test, []).
05:26:12.230 [info] teleport: start server: link://enlil-2:58475 [test]
{ok,<0.275.0>}
3> register(me, self()).
true
```

2) On a client, start a connection and create a new channel

```erlang
2> teleport:connect(test, "link://enlil-2:58475").
true
3> 05:29:44.600 [info] teleport: client connected to peer-node test['test@enlil-2:58475']
 Channel = teleport:new_channel(test).
#{id => 0,link => test,ref => #Ref<0.0.1.3817>}
```

3) Send a simple message:

On the client:

```erlang
4> teleport:send_channel(Channel, me, hello).
ok
```

On the server:

```erlang
4> flush().
Shell got hello
ok
````

4) Send a synchronous request

On the server we will wait on the following message:
 `{'$channel_req', ChannelId::integer(), Pid::pid(), Msg::any()}`
 
```erlang
5> receive
5> {'$channel_req', ChannelId, Pid, Msg} -> Pid ! {got, Msg}
5> end.
```

On the client:

```erlang
5> teleport:send_channel_sync(Channel, me, hello).
{got,hello}

```
6) register/deregister a channel on the server

Using the function `teleport:register_channel/2` and `teleport:unregister_channel/2` 
you have the possibility to register a channel on the server, and let the process 
handling the registration message to send them directly to the process, creating 
a bi-directionnal flux. This allows the creation of simple PUB/SUB systems.

On registration a process on the server will received: `{'$channel_register', ChannelId::integer(), Pid::pid()}`

On de)-registration it will receive: `{'$channel_unregister', ChannelId::integer(), Pid::pid()}`


Build
-----

    $ rebar3 compile
