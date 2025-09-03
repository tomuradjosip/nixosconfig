{
  config,
  pkgs,
  lib,
  secrets,
  ...
}:

{
  # Enable zsh system-wide
  programs.zsh = {
    enable = true;
    shellAliases = {
      # NixOS rebuild aliases
      rb = "sudo nixos-rebuild switch --impure --flake /home/${secrets.username}/nixosconfig#${secrets.hostname}";
      rbt = "sudo nixos-rebuild test --impure --flake /home/${secrets.username}/nixosconfig#${secrets.hostname}";

      # Reset ssh agent
      creds = "ssh-add -D; ssh-add /home/${secrets.username}/.ssh/${secrets.sshPrivateKeyFilename}";

      # Git aliases
      new = "git push --set-upstream origin $(git branch --show-current)";
      squash = "git reset --soft $(git merge-base $(git remote show origin | grep \"HEAD branch\" | awk \"{print \\$3}\") HEAD)";
      amend = "git add .; git commit --no-edit --amend; git push --force-with-lease --force-if-includes";
      undo = "git reset HEAD~";
      cleanup = "git checkout $(git remote show origin | grep \"HEAD branch\" | awk \"{print \\$3}\") && git pull && git fetch --prune && git branch -vv | awk \"/: gone]/{print \\$1}\" | xargs -r -n 1 git branch -D";

      # Better ls
      ll = "ls -lah";
      la = "ls -lah";
    };

    shellInit = ''
      # Example how to include optional pre-commit call
      # ac() { if [ -f .pre-commit-config.yaml ]; then pre-commit run -a; fi; git add .; git commit -m "$1"; }

      # Git functions
      ac() { git add .; git commit -m "$1"; }
      acp() { git add .; git commit -m "$1" && git push; }
      acpf() { git add .; git commit -m "$1" && git push --force-with-lease --force-if-includes; }

      # Initialize oh-my-posh with custom theme
      eval "$(oh-my-posh init zsh --config /home/${secrets.username}/nixosconfig/themes/terminal_theme.json)"
    '';

    ohMyZsh = {
      enable = true;
      plugins = [
        "git"
        "sudo"
        "history"
        "colored-man-pages"
        "zsh-interactive-cd"
        "zsh-navigation-tools"
      ];
    };

    syntaxHighlighting.enable = true;
    autosuggestions.enable = true;
  };

  # Keep bash configuration for compatibility
  programs.bash = {
    shellAliases = {
      # Same aliases available in bash
      rb = "sudo nixos-rebuild switch --impure --flake /home/${secrets.username}/nixosconfig#${secrets.hostname}";
      rbt = "sudo nixos-rebuild test --impure --flake /home/${secrets.username}/nixosconfig#${secrets.hostname}";
    };
  };
}
