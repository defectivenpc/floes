# Identical to catallaxy's, minus the languages this repo has none of, so a
# file formats the same in both and does not churn when it moves.
{

  projectRootFile = "flake.nix";

  programs.nixfmt.enable = true;

  programs.prettier.enable = true;
  programs.prettier.settings = {
    proseWrap = "always";
    printWidth = 76;
  };
}
