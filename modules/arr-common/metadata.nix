{ serviceName }:
{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.nixflix.${serviceName};
  inherit (import ./utils.nix { inherit lib pkgs serviceName; })
    usesMediaDirs
    capitalizedName
    mkSecureCurl
    mkWaitForApiScript
    ;
in
{
  options.nixflix.${serviceName}.config = optionalAttrs usesMediaDirs {
    metadata = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            enable = mkOption {
              type = types.bool;
              default = false;
              description = "Whether to enable this metadata consumer.";
            };
            fields = mkOption {
              type = types.attrsOf types.anything;
              default = { };
              description = ''
                Field values to set, keyed by the field `name` returned by the API.
                Fields not listed here keep their current value.
              '';
            };
          };
        }
      );
      default = { };
      example = literalExpression ''
        {
          PlexMetadata = {
            enable = true;
            fields = {
              seriesPlexMatchFile = true;
              episodeMappings = true;
            };
          };
        }
      '';
      description = ''
        Metadata consumers (Settings → Metadata) to configure via the API /metadata endpoint,
        keyed by the consumer's `implementation` name. Consumers not listed here are left untouched.

        To list the available implementations and their field names, run:

        ```bash
        curl -s -H "X-Api-Key: $(sudo cat </path/to/${serviceName}/api_key>)" "http://127.0.0.1:<port>/api/<apiVersion>/metadata" | jq '.[] | {implementation, fields: [.fields[].name]}'
        ```
      '';
    };
  };

  config =
    mkIf
      (
        usesMediaDirs
        && config.nixflix.enable
        && cfg.enable
        && cfg.config.apiKey != null
        && cfg.config.metadata != { }
      )
      {
        systemd.services."${serviceName}-metadata" = {
          description = "Configure ${serviceName} metadata consumers via API";
          after = [ "${serviceName}-config.service" ] ++ config.nixflix.serviceDependencies;
          requires = [ "${serviceName}-config.service" ] ++ config.nixflix.serviceDependencies;
          wantedBy = [ "multi-user.target" ];

          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStartPre = mkWaitForApiScript serviceName cfg.config;
          };

          script = ''
            set -eu

            BASE_URL="http://${cfg.config.hostConfig.bindAddress}:${builtins.toString cfg.config.hostConfig.port}${cfg.config.hostConfig.urlBase}/api/${cfg.config.apiVersion}"

            echo "Fetching current metadata consumers..."
            METADATA=$(${
              mkSecureCurl cfg.config.apiKey {
                url = "$BASE_URL/metadata";
                extraArgs = "-Sf";
              }
            } 2>/dev/null)

            if [ -z "$METADATA" ]; then
              echo "Failed to fetch metadata consumers"
              exit 1
            fi

            ${concatStringsSep "\n" (
              mapAttrsToList (implementation: consumerConfig: ''
                echo "Configuring metadata consumer: ${implementation}"

                CONSUMER=$(echo "$METADATA" | ${pkgs.jq}/bin/jq --arg impl ${escapeShellArg implementation} \
                  '.[] | select(.implementation == $impl)')

                if [ -z "$CONSUMER" ]; then
                  echo "Metadata consumer not found: ${implementation}"
                  echo "Available: $(echo "$METADATA" | ${pkgs.jq}/bin/jq -r '[.[].implementation] | join(", ")')"
                  exit 1
                fi

                CONSUMER_ID=$(echo "$CONSUMER" | ${pkgs.jq}/bin/jq -r '.id')
                DESIRED=${escapeShellArg (builtins.toJSON consumerConfig)}

                UNKNOWN_FIELDS=$(echo "$CONSUMER" | ${pkgs.jq}/bin/jq -r --argjson desired "$DESIRED" \
                  '($desired.fields | keys) - [.fields[].name] | join(", ")')

                if [ -n "$UNKNOWN_FIELDS" ]; then
                  echo "Unknown fields for ${implementation}: $UNKNOWN_FIELDS"
                  echo "Available: $(echo "$CONSUMER" | ${pkgs.jq}/bin/jq -r '[.fields[].name] | join(", ")')"
                  exit 1
                fi

                NEW_CONSUMER=$(echo "$CONSUMER" | ${pkgs.jq}/bin/jq --argjson desired "$DESIRED" \
                  '.enable = $desired.enable
                   | .fields |= map(.name as $name
                       | if $desired.fields | has($name) then .value = $desired.fields[$name] else . end)')

                PUT_STATUS=$(${
                  mkSecureCurl cfg.config.apiKey {
                    url = "$BASE_URL/metadata/$CONSUMER_ID";
                    method = "PUT";
                    headers = {
                      "Content-Type" = "application/json";
                    };
                    data = "$NEW_CONSUMER";
                    extraArgs = ''-So /tmp/put_response -w "%{http_code}"'';
                  }
                })
                if [ "$PUT_STATUS" -ge 400 ]; then
                  echo "PUT failed (HTTP $PUT_STATUS):"
                  cat /tmp/put_response
                  exit 1
                fi

                echo "Metadata consumer configured: ${implementation}"
              '') cfg.config.metadata
            )}

            echo "${capitalizedName} metadata configuration complete"
          '';
        };
      };
}
