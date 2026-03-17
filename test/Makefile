# Makefile for nginx Lua rate limiting tests

TEST_FILE := test_rate_limiting.t

# Colors
GREEN := \033[0;32m
RED := \033[0;31m
NC := \033[0m

.PHONY: all test clean check-deps install-deps verbose debug help

# Default target
all: test

# Check if Test::Nginx is installed
check-deps:
	@echo "Checking dependencies..."
	@perl -MTest::Nginx -e 1 2>/dev/null || (echo "$(RED)Test::Nginx not installed$(NC)" && exit 1)
	@echo "$(GREEN)Dependencies OK$(NC)"

# Install test dependencies
install-deps:
	@echo "Installing Test::Nginx..."
	sudo cpan -T Test::Nginx::Socket::Lua

# Run tests
test: check-deps
	@echo "$(GREEN)Running nginx rate limiting tests...$(NC)"
	@bash -c 'source .testngxrc && prove $(TEST_FILE)'

# Run tests with verbose output
verbose: check-deps
	@bash -c 'source .testngxrc && prove -v $(TEST_FILE)'

# Run tests in debug mode (keep test files)
debug: check-deps
	@echo "$(GREEN)Running in debug mode - test files will be preserved$(NC)"
	@bash -c 'source .testngxrc && TEST_NGINX_NO_CLEAN=1 prove -v $(TEST_FILE)'
	@echo "$(GREEN)Debug files available in /tmp/nginx_test_servroot/$(NC)"

# Clean test artifacts
clean:
	@echo "Cleaning test artifacts..."
	@rm -rf /tmp/nginx_test_servroot*
	@echo "$(GREEN)Clean complete$(NC)"

# Show test statistics
stats:
	@echo "Test Statistics:"
	@echo "Test cases: $$(grep -h '^=== TEST' $(TEST_FILE) | wc -l)"

# Help
help:
	@echo "nginx Rate Limiting Test Suite"
	@echo ""
	@echo "Tests the token bucket rate limiting implementation using"
	@echo "conf.d/*.conf files via nginx include directives."
	@echo ""
	@echo "Available targets:"
	@echo "  make test         - Run tests (default)"
	@echo "  make verbose      - Run tests with verbose output"
	@echo "  make debug        - Run tests in debug mode (preserves test files)"
	@echo "  make install-deps - Install Test::Nginx dependency"
	@echo "  make clean        - Clean test artifacts"
	@echo "  make stats        - Show test statistics"
	@echo "  make help         - Show this help"
