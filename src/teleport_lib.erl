%% Copyright (c) 2016 Contributors as noted in the AUTHORS file
%%
%% This file is part teleport
%%
%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at http://mozilla.org/MPL/2.0/.

-module(teleport_lib).

-export([
  get_transport/1,
  ssl_conf/2
]).

-include("teleport.hrl").
-include_lib("public_key/include/OTP-PUB-KEY.hrl").

get_transport(tcp) -> ranch_tcp;
get_transport(ssl) -> ranch_ssl;
get_transport(Mod) -> Mod.

-spec ssl_conf(client | server, inet:hostname() | inet:ip_address()) -> proplists:proplists().
ssl_conf(client, Host) ->
  TrustStore = application:get_env(openkvs, client_ssl_store, []),
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
  TrustStore = application:get_env(openkvs, client_ssl_store, []),
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
