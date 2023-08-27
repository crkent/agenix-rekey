{
  self,
  lib,
  pkgs,
  nixosConfigurations,
  ...
} @ inputs: let
  inherit
    (lib)
    any
    assertMsg
    attrNames
    attrValues
    concatStringsSep
    escapeShellArg
    filter
    flip
    foldl'
    hasAttr
    hasPrefix
    head
    length
    mapAttrs
    nameValuePair
    removePrefix
    stringsWithDeps
    warnIf
    ;

  inherit
    (import ../nix/lib.nix inputs)
    userFlakeDir
    ageMasterDecrypt
    ageMasterEncrypt
    ;

  relativeToFlake = filePath: let
    fileStr = builtins.unsafeDiscardStringContext (toString filePath);
  in
    assert assertMsg (hasPrefix userFlakeDir fileStr) "Cannot generate ${fileStr} as it isn't a direct subpath of the flake directory ${userFlakeDir}, meaning this script cannot determine its true origin!";
      "." + removePrefix userFlakeDir fileStr;

  # Finds the host where the given secret is defines. Matches
  # based on secret.id and secret.rekeyFile. If multiple matches
  # exist, a warning is issued and the first is returned.
  findHost = secret: let
    matchingHosts =
      filter
      (host:
        any
        (s: s.id == secret.id && s.rekeyFile == secret.rekeyFile)
        (attrValues nixosConfigurations.${host}.config.age.secrets))
      (attrNames nixosConfigurations);
  in
    warnIf (length matchingHosts > 1) "Multiple hosts provide a secret with rekeyFile=[33m${toString secret.rekeyFile}[m, which may have undesired side effects when used in secret generator dependencies."
    (head matchingHosts);

  # Add the given secret to the set, indexed by its relative path.
  # If the path already exists, this makes sure that the definition is the same.
  addGeneratedSecretChecked = host: set: secretName: let
    secret = nixosConfigurations.${host}.config.age.secrets.${secretName};
    sourceFile = relativeToFlake secret.rekeyFile;
    script = secret.generator._script {
      inherit secret pkgs lib;
      file = sourceFile;
      name = secretName;
      decrypt = ageMasterDecrypt;
      deps = flip map secret.generator.dependencies (dep:
        assert assertMsg (dep.generator != null)
        "The given dependency with rekeyFile=${dep.rekeyFile} is a secret without a generator."; {
          host = findHost dep;
          name = dep.id;
          file = relativeToFlake dep.rekeyFile;
        });
    };
  in
    # Filter secrets that don't need to be generated
    if secret.generator == null
    then set
    else
      # Assert that the generator is the same if it was defined on multiple hosts
      assert assertMsg (hasAttr sourceFile set -> script == set.${sourceFile}.script)
      "Generator definition of ${secretName} on ${host} differs from definitions on other hosts: ${concatStringsSep "," set.${sourceFile}.defs}";
        set
        // {
          ${sourceFile} = {
            inherit secret sourceFile secretName script;
            defs = (set.${sourceFile}.defs or []) ++ ["${host}:${secretName}"];
          };
        };

  # Collects all secrets that have generators across all hosts.
  # Deduplicates secrets if the generator is the same, otherwise throws an error.
  secretsWithContext =
    foldl'
    (set: host:
      foldl' (addGeneratedSecretChecked host) set
      (attrNames nixosConfigurations.${host}.config.age.secrets))
    {} (attrNames nixosConfigurations);

  # The command that actually generates a secret.
  secretGenerationCommand = contextSecret: ''
    if wants_secret ${escapeShellArg contextSecret.sourceFile} ${escapeShellArg (concatStringsSep "," contextSecret.secret.generator.tags)} ; then
      # If the secret has dependencies, force regeneration if any
      # dependency was modified since its last generation
      dep_mtimes=(
        1 # Have at least one entry
        ${concatStringsSep "\n" (flip map contextSecret.secret.generator.dependencies (dep:
          "\"$(stat -c %Y ${escapeShellArg (relativeToFlake dep.rekeyFile)} 2>/dev/null || echo 1)\""
        ))}
      )
      mtime_newest_dep=$(IFS=$'\n'; sort -nr <<< "''${dep_mtimes[*]}" | head -n1)
      mtime_this=$(stat -c %Y ${escapeShellArg contextSecret.sourceFile} 2>/dev/null || echo 0)

      # Regenerate if the file doesn't exist, any dependency is newer, or we should force regeneration
      if [[ ! -e ${escapeShellArg contextSecret.sourceFile} ]] || [[ "$mtime_newest_dep" -gt "$mtime_this" ]] || [[ "$FORCE_GENERATE" == true ]]; then
        echo "Generating secret [34m"${escapeShellArg contextSecret.sourceFile}"[m [90m("${concatStringsSep "', '" (map escapeShellArg contextSecret.defs)}")[m"
        mkdir -p "$(dirname ${escapeShellArg contextSecret.sourceFile})"
        content=$(
          ${contextSecret.script}
        ) || die "Generator exited with status $?."

        ${ageMasterEncrypt} -o ${escapeShellArg contextSecret.sourceFile} <<< "$content" \
          || die "Failed to generate or encrypt secret."

        if [[ "$ADD_TO_GIT" == true ]]; then
          git add ${escapeShellArg contextSecret.sourceFile} \
            || die "Failed to add generated secret to git"
        fi
      else
        echo "[90mSkipping existing secret "${escapeShellArg contextSecret.sourceFile}" ("${concatStringsSep "', '" (map escapeShellArg contextSecret.defs)}")[m"
      fi
    fi
  '';

  # Use stringsWithDeps to compute an ordered list of secret generation commands.
  # Any dependencies of generators are guaranteed to come first, such that
  # generators may use the result of other secrets.
  orderedGenerationCommands = let
    stages = flip mapAttrs secretsWithContext (i: contextSecret:
      stringsWithDeps.fullDepEntry
      (secretGenerationCommand secretsWithContext.${i})
      (map (x: relativeToFlake x.rekeyFile) secretsWithContext.${i}.secret.generator.dependencies));
  in
    stringsWithDeps.textClosureMap (x: x) stages (attrNames stages);
in
  pkgs.writeShellScript "generate-secrets" ''
    set -euo pipefail

    function die() { echo "[1;31merror:[m $*" >&2; exit 1; }
    function show_help() {
      echo 'app generate-secrets - Creates secrets using their generators'
      echo ""
      echo "nix run .#generate-secrets [OPTIONS] [SECRET]..."
      echo ""
      echo 'OPTIONS:'
      echo '-h, --help                Show help'
      echo '-f, --force-generate      Force generating existing secrets'
      echo '-a, --add-to-git          Add generated secrets to git via git add.'
      echo '-t, --tags  TAGS          Additionally select all secrets matching any given tag.'
      echo '                            Takes a comma separated list of tags.'
    }

    FORCE_GENERATE=false
    ADD_TO_GIT=false
    POSITIONAL_ARGS=()
    TAGS=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        "help"|"--help"|"-help"|"-h")
          show_help
          exit 1
          ;;
        "--force-generate"|"-f")
          FORCE_GENERATE=true
          ;;
        "--add-to-git"|"-a")
          ADD_TO_GIT=true
          ;;
        "--tags"|"-t")
          shift
          TAGS="$1"
          ;;
        "--")
          shift
          POSITIONAL_ARGS+=("$@")
          break
          ;;
        "-"*|"--"*) die "Invalid option '$1'" ;;
        *) POSITIONAL_ARGS+=("$1") ;;
      esac
      shift
    done

    # $1: secret file to test if wanted
    # $2: comma separated list of tags that match this secret
    function wants_secret() {
      if [[ ''${#POSITIONAL_ARGS[@]} -eq 0 ]] && [[ -z "$TAGS" ]]; then
        return 0
      else
        for secret in ''${POSITIONAL_ARGS[@]} ; do
          [[ "$(realpath -m "$1")" == "$(realpath -m "$secret")" ]] && return 0
        done
        # Calculate the number of common lines in the splitted tags. Make sure to always include
        # the empty line so TAGS="" $2="" doesn't produce false positives. If more than one line
        # is returned, there is at least once matching tag.
        n_matching=$(comm -12 <(tr ',' '\n' <<< ",''${TAGS}," | sort -u) <(tr ',' '\n' <<< ",$2," | sort -u) | wc -l || echo 1)
        [[ "$n_matching" -gt 1 ]] && return 0
        return 1
      fi
    }

    if [[ ! -e flake.nix ]] ; then
      die "Please execute this script from your flake's root directory."
    fi

    KNOWN_SECRETS=(
      ${concatStringsSep "\n" (map (x: escapeShellArg x.sourceFile) (attrValues secretsWithContext))}
    )
    for secret in ''${POSITIONAL_ARGS[@]} ; do
      for known in ''${KNOWN_SECRETS[@]} ; do
        [[ "$(realpath -m "$secret")" == "$(realpath -m "$known")" ]] && continue 2
      done
      die "Provided path matches no known secret: $secret"
    done

    ${orderedGenerationCommands}
  ''
