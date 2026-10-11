.PHONY: build config check clean

# Build every version in kernel_versions.txt (Linux x86_64 host).
build:
	./build.sh

# Resolve and check configs without compiling.
config:
	CONFIG_ONLY=1 ./build.sh

# Check the stored base configs (works on any OS with bash).
check:
	@for config in configs/x86_64/*.config; do scripts/check-config.sh "$$config" || exit 1; done

clean:
	rm -rf work dist
