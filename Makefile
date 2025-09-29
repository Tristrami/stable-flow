-include .env

.PHONY: anvil-sepolia

anvil-sepolia:
	anvil --fork-url $(SEPOLIA_RPC_URL) --chain-id 31338 --port 8546

