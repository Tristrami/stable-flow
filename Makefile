-include .env

.PHONY: anvil-sepolia

anvil-sepolia:
	anvil --fork-url $(SEPOLIA_RPC_URL) --port 8546

anvil-fuji:
	anvil --fork-url $(FUJI_RPC_URL) --port 8547

