PROJECT_ROOT := $(CURDIR)

.PHONY: setup-ios-runtime run-ios test-ios validate build-ipa clean

setup-ios-runtime:
	@./scripts/ensure_ios_runtime.sh --download

run-ios:
	@./scripts/run_ios.sh run

test-ios:
	@./scripts/run_ios.sh test

validate:
	@python3 scripts/validate.py
	@PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts -p 'test_*.py'

build-ipa:
	@python3 scripts/build_ipa.py

clean:
	@rm -rf "$(PROJECT_ROOT)/.build"
