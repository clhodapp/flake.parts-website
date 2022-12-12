{ config, inputs, lib, flake-parts-lib, ... }:
let
  inherit (lib)
    mkOption
    types
    concatMap
    concatLists
    mapAttrsToList
    attrValues
    hasPrefix
    removePrefix
    ;

in
{
  options.perSystem = flake-parts-lib.mkPerSystemOption ({ config, pkgs, lib, ... }:
    let
      cfg = config.render;

      fixups = { lib, flake-parts-lib, ... }: {
        options.perSystem = flake-parts-lib.mkPerSystemOption {
          config = {
            _module.args.pkgs = {
              formats = lib.mapAttrs
                (formatName: formatFn:
                  formatArgs:
                  let
                    result = formatFn formatArgs;
                    stubs =
                      lib.mapAttrs
                        (name: _:
                          throw "The attribute `(pkgs.formats.${lib.strings.escapeNixIdentifier formatName} x).${lib.strings.escapeNixIdentifier name}` is not supported during documentation generation. Please check with `--show-trace` to see which option leads to this `${lib.strings.escapeNixIdentifier name}` reference. Often it can be cut short with a `defaultText` argument to `lib.mkOption`, or by escaping an option `example` using `lib.literalExpression`."
                        )
                        result;
                  in
                  stubs // {
                    inherit (result) type;
                  }
                )
                pkgs.formats;
            };
          };
        };
      };

      eval = inputs.flake-parts.lib.evalFlakeModule
        {
          self = { inputs = { inherit (inputs) nixpkgs; }; };
        }
        {
          imports =
            concatLists (mapAttrsToList (name: inputCfg: inputCfg.getModules inputCfg.flake) cfg.inputs)
            ++ [
              fixups
            ];
        };

      opts = eval.options;

      filterTransformOptions = { sourceName, sourcePath, baseUrl }:
        let sourcePathStr = toString sourcePath;
        in
        opt:
        let
          declarations = concatMap
            (decl:
              if hasPrefix sourcePathStr (toString decl)
              then
                let subpath = removePrefix sourcePathStr (toString decl);
                in [{ url = baseUrl + subpath; name = sourceName + subpath; }]
              else [ ]
            )
            opt.declarations;
        in
        if declarations == [ ]
        then opt // { visible = false; }
        else opt // { inherit declarations; };


      inputModule = { config, name, ... }: {
        options = {
          flake = mkOption {
            type = types.raw;
            description = ''
              A flake.
            '';
            default = inputs.${name};
          };

          sourcePath = mkOption {
            type = types.path;
            description = ''
              Source path in which the modules are contained.
            '';
            default = config.flake.outPath;
          };

          title = mkOption {
            type = types.str;
            description = ''
              Title of the markdown page.
            '';
            default = name;
          };

          flakeRef = mkOption {
            type = types.str;
            default =
              # This only works for github for now, but we can set a non-default
              # value in the list just fine.
              let
                match = builtins.match "https://github.com/([^/]*)/([^/]*)/blob/([^/]*)" config.baseUrl;
                owner = lib.elemAt match 0;
                repo = lib.elemAt match 1;
                branch = lib.elemAt match 2; # ignored for now because they're all default branches
              in
              if match != null
              then "github:${owner}/${repo}"
              else throw "Couldn't figure out flakeref for ${name}";
          };

          preface = mkOption {
            type = types.str;
            description = ''
              Stuff between the title and the options.
            '';
            default = ''

              ${config.intro}

              ${config.installation}

            '';
          };

          intro = mkOption {
            type = types.str;
            description = ''
              Introductory paragraph between title and installation.
            '';
          };

          installation = mkOption {
            type = types.str;
            description = ''
              Installation paragraph between installation and options.
            '';
            default =
              ''
                ## Installation

                To use these options, add to your flake inputs:

                ```nix
                ${config.sourceName}.url = "${config.flakeRef}";
                ```

                and inside the `mkFlake`:

                ```nix
                imports = [
                   inputs.${config.sourceName}.${lib.concatMapStringsSep "." lib.strings.escapeNixIdentifier config.attributePath}
                ];
                ```

                Run `nix flake lock` and you're set.
              '';
          };

          sourceName = mkOption {
            type = types.str;
            description = ''
              Name by which the source is shown in the list of declarations.
            '';
            default = name;
          };

          baseUrl = mkOption {
            type = types.str;
            description = ''
              URL prefix for source location links.
            '';
          };

          getModules = mkOption {
            type = types.functionTo (types.listOf types.raw);
            description = ''
              Get the modules to render.
            '';
            default = flake: [
              (builtins.addErrorContext "while getting modules for input '${name}'"
                (lib.getAttrFromPath config.attributePath flake)
              )
            ];
          };

          attributePath = mkOption {
            type = types.listOf types.str;
            description = ''
              Flake output attribute path to import.
            '';
            default = [ "flakeModule" ];
          };

          rendered = mkOption {
            type = types.package;
            description = ''
              Built Markdown docs.
            '';
            readOnly = true;
          };

          _nixosOptionsDoc = mkOption { };
        };
        config = {
          _nixosOptionsDoc = pkgs.nixosOptionsDoc {
            options = opts;
            documentType = "none";
            transformOptions = filterTransformOptions {
              inherit (config) sourceName baseUrl sourcePath;
            };
            warningsAreErrors = true; # not sure if feasible long term
            markdownByDefault = true;
          };
          rendered = pkgs.runCommand "option-doc-${config.sourceName}"
            {
              nativeBuildInputs = [ pkgs.libxslt.bin pkgs.pandoc ];
              inputDoc = config._nixosOptionsDoc.optionsDocBook;
              inherit (config) title preface;
            } ''
            xsltproc --stringparam title "$title" \
              -o options.db.xml ${./options.xsl} \
              "$inputDoc"
            mkdir $out
            pandoc --verbose --from docbook --to html options.db.xml >options.html
            substitute options.html $out/options.html --replace '<p>@intro@</p>' "$preface"
            grep -v '@intro@' <$out/options.html >/dev/null || {
              grep '@intro@' <$out/options.html
              echo intro replacement failed; exit 1;
            }
          '';
        };
      };
    in
    {
      options = {
        render = {
          inputs = mkOption {
            description = "Which modules to render.";
            type = types.attrsOf (types.submodule inputModule);
          };
        };
      };
      config = {
        packages = lib.mapAttrs' (name: inputCfg: { name = "generated-docs-${name}"; value = inputCfg.rendered; }) cfg.inputs // {
          generated-docs =
            pkgs.runCommand "generated-docs"
              { }
              ''
                mkdir $out
                ${lib.concatStringsSep "\n"
                  (lib.mapAttrsToList
                    (name: inputCfg: ''
                      cp ${inputCfg.rendered}/options.html $out/${name}.html
                    '')
                    cfg.inputs)
                }
              '';
        };
      };
    });
}
