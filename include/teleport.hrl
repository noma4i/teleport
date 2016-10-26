%% Copyright (c) 2016 Contributors as noted in the AUTHORS file
%%
%% This file is part teleport
%%
%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at http://mozilla.org/MPL/2.0/.

-define(DEFAULT_PORT, 7090).

-define(SSL_DEFAULT_COMMON_OPTS, [binary,
  %% SSL options
  {ciphers,["ECDHE-ECDSA-AES256-GCM-SHA384","ECDHE-RSA-AES256-GCM-SHA384",
    "ECDHE-ECDSA-AES256-SHA384","ECDHE-RSA-AES256-SHA384","ECDHE-ECDSA-DES-CBC3-SHA",
    "ECDH-ECDSA-AES256-GCM-SHA384","ECDH-RSA-AES256-GCM-SHA384","ECDH-ECDSA-AES256-SHA384",
    "ECDH-RSA-AES256-SHA384","DHE-DSS-AES256-GCM-SHA384","DHE-DSS-AES256-SHA256",
    "AES256-GCM-SHA384","AES256-SHA256","ECDHE-ECDSA-AES128-GCM-SHA256",
    "ECDHE-RSA-AES128-GCM-SHA256","ECDHE-ECDSA-AES128-SHA256","ECDHE-RSA-AES128-SHA256",
    "ECDH-ECDSA-AES128-GCM-SHA256","ECDH-RSA-AES128-GCM-SHA256","ECDH-ECDSA-AES128-SHA256",
    "ECDH-RSA-AES128-SHA256","DHE-DSS-AES128-GCM-SHA256","DHE-DSS-AES128-SHA256","AES128-GCM-SHA256",
    "AES128-SHA256","ECDHE-ECDSA-AES256-SHA","ECDHE-RSA-AES256-SHA","DHE-DSS-AES256-SHA",
    "ECDH-ECDSA-AES256-SHA","ECDH-RSA-AES256-SHA","AES256-SHA","ECDHE-ECDSA-AES128-SHA",
    "ECDHE-RSA-AES128-SHA","DHE-DSS-AES128-SHA","ECDH-ECDSA-AES128-SHA","ECDH-RSA-AES128-SHA","AES128-SHA"]},
  {secure_renegotiate,true},
  {reuse_sessions,true},
  {versions,['tlsv1.2','tlsv1.1']},
  {verify,verify_peer},
  {hibernate_after,600000}]).

-define(SSL_DEFAULT_SERVER_OPTS, [{fail_if_no_peer_cert,true},
  {log_alert,false},
  {honor_cipher_order,true},
  {client_renegotiation,true}]).

-define(SSL_DEFAULT_CLIENT_OPTS, [{server_name_indication,disable},
  {depth,99}]).


-define(DEFAULT_TCP_OPTS, [binary, {active,false}]). % Retrieve data from socket upon request
