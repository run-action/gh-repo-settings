{
  description = "gh-settings: settings.yml sync CLI, plus a lint dev shell";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { self, nixpkgs }:
    let
      forAllSystems = nixpkgs.lib.genAttrs [
        "aarch64-darwin"
        "x86_64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];
      linters =
        pkgs: with pkgs; [
          shellcheck
          shfmt
          yamllint
          actionlint
          zizmor
        ];
    in
    {
      # `nix run .# -- sync --dry-run` etc.; runtime deps wrapped in.
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.stdenvNoCC.mkDerivation {
            pname = "gh-settings";
            version = "0-unstable";
            src = self;
            nativeBuildInputs = [ pkgs.makeWrapper ];
            installPhase = ''
              runHook preInstall
              mkdir -p $out/libexec
              cp gh-settings $out/libexec/
              cp -r scripts $out/libexec/scripts
              makeWrapper $out/libexec/gh-settings $out/bin/gh-settings \
                --prefix PATH : ${
                  pkgs.lib.makeBinPath (
                    with pkgs;
                    [
                      yq-go
                      jq
                      curl
                      gh
                    ]
                  )
                }
              runHook postInstall
            '';
            meta.mainProgram = "gh-settings";
          };
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          # `lint` — run every linter the CI runs, plus zizmor.
          lint = pkgs.writeShellApplication {
            name = "lint";
            runtimeInputs = linters pkgs;
            text = ''
              shellcheck scripts/*.sh gh-settings tests/stubs/curl
              shfmt -d scripts/*.sh gh-settings tests/stubs/curl
              yamllint --strict .
              actionlint
              zizmor .
              echo "All linters passed."
            '';
          };
          # `test` — the bats suite.
          test = pkgs.writeShellApplication {
            name = "test";
            runtimeInputs = with pkgs; [
              bats
              yq-go
              jq
              git
            ];
            text = ''
              exec bats "''${@:-tests/}"
            '';
          };
        in
        {
          default = pkgs.mkShell {
            packages =
              linters pkgs
              ++ [
                lint
                test
              ]
              # Runtime deps of the scripts themselves, plus the test runner.
              ++ (with pkgs; [
                yq-go
                jq
                gh
                bats
              ]);
          };
        }
      );
    };
}
