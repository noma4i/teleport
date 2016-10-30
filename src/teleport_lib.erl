%% Copyright (c) 2016 Contributors as noted in the AUTHORS file
%%
%% This file is part teleport
%%
%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at http://mozilla.org/MPL/2.0/.

-module(teleport_lib).

-export([
  ssl_conf/2,
  sync_kill/1,
  to_atom/1,
  to_list/1
]).

-include("teleport.hrl").
-include_lib("public_key/include/OTP-PUB-KEY.hrl").


-spec ssl_conf(client | server, inet:hostname() | inet:ip_address()) -> proplists:proplists().
ssl_conf(client, Host) ->
  TrustStore = application:get_env(teleport, client_ssl_store, []),
  ExtraOpts0 = proplists:get_value(Host, TrustStore, []),
  DefaultOpts = lists:append(?SSL_DEFAULT_COMMON_OPTS, ?SSL_DEFAULT_CLIENT_OPTS),
  Insecure =  proplists:get_value(insecure, ExtraOpts0),
  CACerts = certifi:cacerts(),
  ExtraOpts = case Insecure of
                true -> [{verify, verify_none}];
                false ->
                  VerifyFun = {fun ssl_verify_hostname:verify_fun/3,  [{check_hostname, Host}]},
                  [
                    {cacerts, CACerts},
                    {partial_chain, fun partial_chain/1},
                    {verify_fun, VerifyFun} | ExtraOpts0
                  ]
              end,
  merge_opts(ExtraOpts, DefaultOpts);
ssl_conf(server, Host) ->
  TrustStore = application:get_env(teleport, server_ssl_store, []),
  ExtraOpts = proplists:get_value(Host, TrustStore, []),
  DefaultOpts = lists:append(?SSL_DEFAULT_COMMON_OPTS, ?SSL_DEFAULT_SERVER_OPTS),
  merge_opts(ExtraOpts, DefaultOpts).

merge_opts(List1, List2) ->
  SList1 = lists:usort(fun props_compare/2, List1),
  SList2 = lists:usort(fun props_compare/2, List2),
  lists:umerge(fun props_compare/2, SList1, SList2).

props_compare({K1,_V1}, {K2,_V2}) -> K1 =< K2;
props_compare(K1, K2) -> K1 =< K2.


%% code from rebar3 undert BSD license
partial_chain(Certs) ->
  Certs1 = lists:reverse([{Cert, public_key:pkix_decode_cert(Cert, otp)} ||
    Cert <- Certs]),
  CACerts = certifi:cacerts(),
  CACerts1 = [public_key:pkix_decode_cert(Cert, otp) || Cert <- CACerts],


  case find(fun({_, Cert}) ->
    check_cert(CACerts1, Cert)
            end, Certs1) of
    {ok, Trusted} ->
      {trusted_ca, element(1, Trusted)};
    _ ->
      unknown_ca
  end.

extract_public_key_info(Cert) ->
  ((Cert#'OTPCertificate'.tbsCertificate)#'OTPTBSCertificate'.subjectPublicKeyInfo).

check_cert(CACerts, Cert) ->
  lists:any(fun(CACert) ->
    extract_public_key_info(CACert) == extract_public_key_info(Cert)
            end, CACerts).

-spec find(fun(), list()) -> {ok, term()} | error.
find(Fun, [Head|Tail]) when is_function(Fun) ->
  case Fun(Head) of
    true ->
      {ok, Head};
    false ->
      find(Fun, Tail)
  end;
find(_Fun, []) ->
  error.

sync_kill(Pid) ->
  MRef = erlang:monitor(process, Pid),
  try
      catch unlink(Pid),
      catch exit(Pid, kill),
    receive
      {'DOWN', MRef, _, _, _} ->
        ok
    end
  after
    erlang:demonitor(MRef, [flush])
  end.

-spec to_atom(term()) -> atom().
to_atom(V) when is_atom(V) -> V;
to_atom(V) when is_list(V) ->
  case catch list_to_existing_atom(V) of
    {'EXIT', _} -> list_to_atom(V);
    A -> A
  end;
to_atom(V) when is_binary(V) ->
  case catch binary_to_existing_atom(V, utf8) of
    {'EXIT', _} -> binary_to_atom(V, utf8);
    B -> B
  end;
to_atom(_) -> error(badarg).


to_list(V) when is_list(V) -> V;
to_list(V) when is_binary(V) -> binary_to_list(V);
to_list(V) when is_atom(V) -> atom_to_list(V);
to_list(V) when is_list(V) -> integer_to_list(V);
to_list(_) -> error(badarg).
