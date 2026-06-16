include .env

export

# Install

install: install-hooks
	forge install

install-hooks:
	@hook_path=$$(git rev-parse --git-path hooks/pre-commit 2>/dev/null); \
	if [ -n "$$hook_path" ]; then \
		mkdir -p "$$(dirname "$$hook_path")"; \
		ln -sf "$$(pwd)/.githooks/pre-commit" "$$hook_path"; \
		chmod +x .githooks/pre-commit; \
		echo "Installed pre-commit hook at $$hook_path"; \
	else \
		echo "Skipping hook install: not in a git repository"; \
	fi

# Test

test:
	forge test --show-progress

coverage:
	forge coverage --ir-minimum --report lcov

fuzz:
	forge test --mt invariant_ --show-progress

deep-fuzz:
	FOUNDRY_PROFILE=deep forge test --mt invariant_ --show-progress

# Logs

generate-history:
	@bun run ./deployments/cli.ts --output history
