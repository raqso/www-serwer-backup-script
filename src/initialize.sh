# Runs before the dependency checks of every command.
# Prefer the tools installed by 'wsb install' over older system-wide ones, also under cron's
# minimal PATH, and make freshly installed tools usable right away (sourcing ~/.bashrc does
# nothing in a non-interactive shell).
export PATH="$HOME/bin:$PATH"
