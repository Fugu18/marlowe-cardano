{ inputs }:
let
  inherit (inputs) self std nixpkgs bitte-cells;
  inherit (self) packages;
  inherit (nixpkgs) lib;
  inherit (nixpkgs.legacyPackages)
    jq
    sqitchPg
    postgresql
    coreutils
    writeShellScriptBin
    socat
    netcat
    ;
  inherit (inputs.bitte-cells._utils.packages) srvaddr;

  # Ensure this path only changes when sqitch.plan file is updated
  sqitch-plan-dir = (builtins.path {
    path = self;
    name = "marlowe-chain-sync-sqitch-plan";
    filter = path: type:
      path == "${self}/marlowe-chain-sync"
        || path == "${self}/marlowe-chain-sync/sqitch.plan"
        || lib.hasPrefix "${self}/marlowe-chain-sync/deploy" path
        || lib.hasPrefix "${self}/marlowe-chain-sync/revert" path;
  }) + "/marlowe-chain-sync";

  database-uri = "postgresql://$DB_USER:$DB_PASS@$DB_HOST/$DB_NAME";

  wait-for-socket = writeShellScriptBin "wait-for-socket" ''
    set -eEuo pipefail

    export PATH="${lib.makeBinPath [ coreutils socat ]}"

    sock_path="$1"
    delay_iterations="''${2:-8}"

    for ((i=0;i<delay_iterations;i++))
    do
      if socat -u OPEN:/dev/null "UNIX-CONNECT:''${sock_path}"
      then
        exit 0
      fi
      let delay=2**i
      echo "Connecting to ''${sock_path} failed, sleeping for ''${delay} seconds" >&2
      sleep "''${delay}"
    done

    socat -u OPEN:/dev/null "UNIX-CONNECT:''${sock_path}"
  '';

  wait-for-tcp = writeShellScriptBin "wait-for-tcp" ''
    set -eEuo pipefail

    export PATH="${lib.makeBinPath [ coreutils netcat ]}"

    ip="$1"
    port="$2"
    delay_iterations="''${3:-8}"

    for ((i=0;i<delay_iterations;i++))
    do
      if nc -v -w 2 -z "$ip" "$port"
      then
        exit 0
      fi
      let delay=2**i
      echo "Connecting to ''${ip}:''${port} failed, sleeping for ''${delay} seconds" >&2
      sleep "''${delay}"
    done

    nc -v -w 2 -z "$ip" "$port"
  '';

  inherit (std.lib.ops) mkOperable;

in
{
  chain-indexer = mkOperable {
    package = packages.marlowe-chain-indexer;
    runtimeInputs = [ jq sqitchPg srvaddr postgresql coreutils ];
    runtimeScript = ''
      #################
      # REQUIRED VARS #
      #################
      # NODE_CONFIG: path to the cardano node config file
      # CARDANO_NODE_SOCKET_PATH: path to the node socket
      # DB_NAME, DB_USER, DB_PASS,
      # Either DB_HOST or MASTER_REPLICA_SRV_DNS (for auto-discovery of DB host with srvaddr)

      [ -z "''${NODE_CONFIG:-}" ] && echo "NODE_CONFIG env var must be set -- aborting" && exit 1
      [ -z "''${CARDANO_NODE_SOCKET_PATH:-}" ] && echo "CARDANO_NODE_SOCKET_PATH env var must be set -- aborting" && exit 1
      [ -z "''${DB_NAME:-}" ] && echo "DB_NAME env var must be set -- aborting" && exit 1
      [ -z "''${DB_USER:-}" ] && echo "DB_USER env var must be set -- aborting" && exit 1
      [ -z "''${DB_PASS:-}" ] && echo "DB_PASS env var must be set -- aborting" && exit 1

      if [ -n "''${MASTER_REPLICA_SRV_DNS:-}" ]; then
        # Find DB_HOST when running on bitte cluster with patroni
        eval "$(srvaddr -env PSQL="$MASTER_REPLICA_SRV_DNS")"
        # produces: PSQL_ADDR0=domain:port; PSQL_HOST0=domain; PSQL_PORT0=port
        DB_HOST=$PSQL_ADDR0
      fi

      [ -z "''${DB_HOST:-}" ] && echo "DB_HOST env var must be set -- aborting" && exit 1

      DATABASE_URI=${database-uri}
      cd ${sqitch-plan-dir}
      mkdir -p /tmp
      HOME="$(mktemp -d)" # Ensure HOME is writable for sqitch config
      export TZ=Etc/UTC
      sqitch config --user user.name chainindexer
      sqitch config --user user.email example@example.com
      sqitch --quiet deploy --target "$DATABASE_URI"
      cd -

      NODE_CONFIG_DIR=$(dirname "$NODE_CONFIG")
      BYRON_GENESIS_CONFIG="$NODE_CONFIG_DIR/$(jq -r .ByronGenesisFile "$NODE_CONFIG")"
      SHELLEY_GENESIS_CONFIG="$NODE_CONFIG_DIR/$(jq -r .ShelleyGenesisFile "$NODE_CONFIG")"
      BYRON_GENESIS_HASH=$(jq -r '.ByronGenesisHash' "$NODE_CONFIG")
      CARDANO_TESTNET_MAGIC=$(jq -r '.networkMagic' "$SHELLEY_GENESIS_CONFIG");
      export CARDANO_TESTNET_MAGIC

      ${wait-for-socket}/bin/wait-for-socket "$CARDANO_NODE_SOCKET_PATH"

      ${packages.marlowe-chain-indexer}/bin/marlowe-chain-indexer \
        --socket-path "$CARDANO_NODE_SOCKET_PATH" \
        --database-uri  "$DATABASE_URI" \
        --shelley-genesis-config-file "$SHELLEY_GENESIS_CONFIG" \
        --genesis-config-file "$BYRON_GENESIS_CONFIG" \
        --genesis-config-file-hash "$BYRON_GENESIS_HASH"
    '';
  };

  marlowe-chain-sync = mkOperable {
    package = packages.marlowe-chain-sync;
    runtimeInputs = [ srvaddr jq coreutils ];
    runtimeScript = ''
      #################
      # REQUIRED VARS #
      #################
      # HOST, PORT, QUERY_PORT, JOB_PORT: network binding
      # CARDANO_NODE_SOCKET_PATH: path to the node socket
      # DB_NAME, DB_USER, DB_PASS,
      # Either DB_HOST or MASTER_REPLICA_SRV_DNS (for auto-discovery of DB host with srvaddr)

      [ -z "''${HOST:-}" ] && echo "HOST env var must be set -- aborting" && exit 1
      [ -z "''${PORT:-}" ] && echo "PORT env var must be set -- aborting" && exit 1
      [ -z "''${QUERY_PORT:-}" ] && echo "QUERY_PORT env var must be set -- aborting" && exit 1
      [ -z "''${JOB_PORT:-}" ] && echo "JOB_PORT env var must be set -- aborting" && exit 1
      [ -z "''${CARDANO_NODE_SOCKET_PATH:-}" ] && echo "CARDANO_NODE_SOCKET_PATH env var must be set -- aborting" && exit 1
      [ -z "''${DB_NAME:-}" ] && echo "DB_NAME env var must be set -- aborting" && exit 1
      [ -z "''${DB_USER:-}" ] && echo "DB_USER env var must be set -- aborting" && exit 1
      [ -z "''${DB_PASS:-}" ] && echo "DB_PASS env var must be set -- aborting" && exit 1

      if [ -n "''${MASTER_REPLICA_SRV_DNS:-}" ]; then
        # Find DB_HOST when running on bitte cluster with patroni
        eval "$(srvaddr -env PSQL="$MASTER_REPLICA_SRV_DNS")"
        # produces: PSQL_ADDR0=domain:port; PSQL_HOST0=domain; PSQL_PORT0=port
        DB_HOST=$PSQL_ADDR0
      fi
      [ -z "''${DB_HOST:-}" ] && echo "DB_HOST env var must be set -- aborting" && exit 1

      NODE_CONFIG_DIR=$(dirname "$NODE_CONFIG")
      SHELLEY_GENESIS_CONFIG="$NODE_CONFIG_DIR/$(jq -r .ShelleyGenesisFile "$NODE_CONFIG")"
      CARDANO_TESTNET_MAGIC=$(jq -r '.networkMagic' "$SHELLEY_GENESIS_CONFIG");
      export CARDANO_TESTNET_MAGIC

      ${wait-for-socket}/bin/wait-for-socket "$CARDANO_NODE_SOCKET_PATH"

      DATABASE_URI=${database-uri}
      ${packages.marlowe-chain-sync}/bin/marlowe-chain-sync \
        --host "$HOST" \
        --port "$PORT" \
        --query-port "$QUERY_PORT" \
        --job-port "$JOB_PORT" \
        --socket-path "$CARDANO_NODE_SOCKET_PATH" \
        --database-uri  "$DATABASE_URI"
    '';
  };
  marlowe-history = mkOperable {
    package = packages.marlowe-history;
    runtimeScript = ''
      #################
      # REQUIRED VARS #
      #################
      # HOST, PORT, QUERY_PORT, SYNC_PORT: network binding
      # MARLOWE_CHAIN_SYNC_HOST, MARLOWE_CHAIN_SYNC_PORT, MARLOWE_CHAIN_SYNC_QUERY_PORT: connection info to marlowe-chain-sync

      [ -z "''${HOST:-}" ] && echo "HOST env var must be set -- aborting" && exit 1
      [ -z "''${PORT:-}" ] && echo "PORT env var must be set -- aborting" && exit 1
      [ -z "''${QUERY_PORT:-}" ] && echo "QUERY_PORT env var must be set -- aborting" && exit 1
      [ -z "''${SYNC_PORT:-}" ] && echo "SYNC_PORT env var must be set -- aborting" && exit 1
      [ -z "''${MARLOWE_CHAIN_SYNC_HOST:-}" ] && echo "MARLOWE_CHAIN_SYNC_HOST env var must be set -- aborting" && exit 1
      [ -z "''${MARLOWE_CHAIN_SYNC_PORT:-}" ] && echo "MARLOWE_CHAIN_SYNC_PORT env var must be set -- aborting" && exit 1
      [ -z "''${MARLOWE_CHAIN_SYNC_QUERY_PORT:-}" ] && echo "MARLOWE_CHAIN_SYNC_QUERY_PORT env var must be set -- aborting" && exit 1

      ${wait-for-tcp}/bin/wait-for-tcp "$MARLOWE_CHAIN_SYNC_HOST" "$MARLOWE_CHAIN_SYNC_PORT"

      ${packages.marlowe-history}/bin/marlowe-history \
        --host "$HOST" \
        --command-port "$PORT" \
        --query-port "$QUERY_PORT" \
        --sync-port "$SYNC_PORT" \
        --chain-sync-port "$MARLOWE_CHAIN_SYNC_PORT" \
        --chain-sync-query-port "$MARLOWE_CHAIN_SYNC_QUERY_PORT" \
        --chain-sync-host "$MARLOWE_CHAIN_SYNC_HOST"
    '';
  };
  marlowe-discovery = mkOperable {
    package = packages.marlowe-discovery;
    runtimeScript = ''
      #################
      # REQUIRED VARS #
      #################
      # HOST, PORT, SYNC_PORT: network binding
      # MARLOWE_CHAIN_SYNC_HOST, MARLOWE_CHAIN_SYNC_PORT, MARLOWE_CHAIN_SYNC_QUERY_PORT: connection info to marlowe-chain-sync

      [ -z "''${HOST:-}" ] && echo "HOST env var must be set -- aborting" && exit 1
      [ -z "''${PORT:-}" ] && echo "PORT env var must be set -- aborting" && exit 1
      [ -z "''${SYNC_PORT:-}" ] && echo "SYNC_PORT env var must be set -- aborting" && exit 1
      [ -z "''${MARLOWE_CHAIN_SYNC_HOST:-}" ] && echo "MARLOWE_CHAIN_SYNC_HOST env var must be set -- aborting" && exit 1
      [ -z "''${MARLOWE_CHAIN_SYNC_PORT:-}" ] && echo "MARLOWE_CHAIN_SYNC_PORT env var must be set -- aborting" && exit 1
      [ -z "''${MARLOWE_CHAIN_SYNC_QUERY_PORT:-}" ] && echo "MARLOWE_CHAIN_SYNC_QUERY_PORT env var must be set -- aborting" && exit 1

      ${wait-for-tcp}/bin/wait-for-tcp "$MARLOWE_CHAIN_SYNC_HOST" "$MARLOWE_CHAIN_SYNC_PORT"

      ${packages.marlowe-discovery}/bin/marlowe-discovery \
        --host "$HOST" \
        --query-port "$PORT" \
        --sync-port "$SYNC_PORT" \
        --chain-sync-port "$MARLOWE_CHAIN_SYNC_PORT" \
        --chain-sync-query-port "$MARLOWE_CHAIN_SYNC_QUERY_PORT" \
        --chain-sync-host "$MARLOWE_CHAIN_SYNC_HOST"
    '';
  };
  marlowe-tx = mkOperable {
    package = packages.marlowe-tx;
    runtimeScript = ''
      #################
      # REQUIRED VARS #
      #################
      # HOST, PORT: network binding
      # MARLOWE_CHAIN_SYNC_HOST, MARLOWE_CHAIN_SYNC_PORT, MARLOWE_CHAIN_SYNC_QUERY_PORT, MARLOWE_CHAIN_SYNC_COMMAND_PORT: connection info to marlowe-chain-sync

      [ -z "''${HOST:-}" ] && echo "HOST env var must be set -- aborting" && exit 1
      [ -z "''${PORT:-}" ] && echo "PORT env var must be set -- aborting" && exit 1
      [ -z "''${MARLOWE_CHAIN_SYNC_HOST:-}" ] && echo "MARLOWE_CHAIN_SYNC_HOST env var must be set -- aborting" && exit 1
      [ -z "''${MARLOWE_CHAIN_SYNC_PORT:-}" ] && echo "MARLOWE_CHAIN_SYNC_PORT env var must be set -- aborting" && exit 1
      [ -z "''${MARLOWE_CHAIN_SYNC_COMMAND_PORT:-}" ] && echo "MARLOWE_CHAIN_SYNC_COMMAND_PORT env var must be set -- aborting" && exit 1
      [ -z "''${MARLOWE_CHAIN_SYNC_QUERY_PORT:-}" ] && echo "MARLOWE_CHAIN_SYNC_QUERY_PORT env var must be set -- aborting" && exit 1

      ${wait-for-tcp}/bin/wait-for-tcp "$MARLOWE_CHAIN_SYNC_HOST" "$MARLOWE_CHAIN_SYNC_PORT"

      ${packages.marlowe-tx}/bin/marlowe-tx \
        --host "$HOST" \
        --command-port "$PORT" \
        --chain-sync-port "$MARLOWE_CHAIN_SYNC_PORT" \
        --chain-sync-query-port "$MARLOWE_CHAIN_SYNC_QUERY_PORT" \
        --chain-sync-command-port "$MARLOWE_CHAIN_SYNC_COMMAND_PORT" \
        --chain-sync-host "$MARLOWE_CHAIN_SYNC_HOST" \
    '';
  };
}
