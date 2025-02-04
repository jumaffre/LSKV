BUILD=build
CCF_PREFIX=/opt/ccf

CC=/opt/oe_lvi/clang-10
CXX=/opt/oe_lvi/clang++-10

ETCD_VER=v3.5.4
ETCD_DOWNLOAD_URL=https://github.com/etcd-io/etcd/releases/download

CPP_FILES=$(wildcard src/**/*.cpp)
H_FILES=$(wildcard src/**/*.h)

BIN_DIR=bin

CCF_VER=ccf-3.0.0-dev6
CCF_VER_LOWER=ccf_3.0.0_dev6

.PHONY: install-ccf
install-ccf:
	wget -c https://github.com/microsoft/CCF/releases/download/$(CCF_VER)/$(CCF_VER_LOWER)_amd64.deb # download deb
	sudo dpkg -i $(CCF_VER_LOWER)_amd64.deb # Installs CCF under /opt/ccf
	/opt/ccf/getting_started/setup_vm/run.sh /opt/ccf/getting_started/setup_vm/app-dev.yml  # Install dependencies

.PHONY: build-virtual
build-virtual:
	mkdir -p $(BUILD)
	cd $(BUILD)
	cd $(BUILD) && CC=$(CC) CXX=$(CXX) cmake -DCOMPILE_TARGETS=virtual -DCMAKE_EXPORT_COMPILE_COMMANDS=1 -GNinja ..
	cd $(BUILD) && ninja

.PHONY: build-sgx
build-sgx:
	mkdir -p $(BUILD)
	cd $(BUILD)
	cd $(BUILD) && CC=$(CC) CXX=$(CXX) cmake -DCOMPILE_TARGETS=sgx -DCMAKE_EXPORT_COMPILE_COMMANDS=1 -GNinja ..
	cd $(BUILD) && ninja

.PHONY: run-virtual
run-virtual: build-virtual
	$(CCF_PREFIX)/bin/sandbox.sh -p $(BUILD)/liblskv.virtual.so --http2

.PHONY: run-sgx
run-sgx: build-sgx
	$(CCF_PREFIX)/bin/sandbox.sh -p $(BUILD)/liblskv.enclave.so.signed -e release --http2

.PHONY: test-virtual
test-virtual: build-virtual patched-etcd
	./integration-tests.sh -v

.PHONY: patched-etcd
patched-etcd:
	rm -rf $(BUILD)/3rdparty/etcd
	mkdir -p $(BUILD)/3rdparty
	cp -r 3rdparty/etcd $(BUILD)/3rdparty/.
	git apply --directory=$(BUILD)/3rdparty/etcd patches/*

$(BIN_DIR)/benchmark: patched-etcd
	cd $(BUILD)/3rdparty/etcd && go build -buildvcs=false ./tools/benchmark
	mkdir -p $(BIN_DIR)
	mv $(BUILD)/3rdparty/etcd/benchmark $(BIN_DIR)/benchmark

$(BIN_DIR)/etcd:
	rm -f /tmp/etcd-$(ETCD_VER)-linux-amd64.tar.gz
	rm -rf /tmp/etcd-download-test && mkdir -p /tmp/etcd-download-test
	curl -L $(ETCD_DOWNLOAD_URL)/$(ETCD_VER)/etcd-$(ETCD_VER)-linux-amd64.tar.gz -o /tmp/etcd-$(ETCD_VER)-linux-amd64.tar.gz
	tar xzvf /tmp/etcd-$(ETCD_VER)-linux-amd64.tar.gz -C /tmp/etcd-download-test --strip-components=1
	rm -f /tmp/etcd-$(ETCD_VER)-linux-amd64.tar.gz
	mkdir -p $(BIN_DIR)
	mv /tmp/etcd-download-test/etcdctl $(BIN_DIR)/etcdctl
	mv /tmp/etcd-download-test/etcd $(BIN_DIR)/etcd

$(BIN_DIR)/etcdctl: $(BIN_DIR)/etcd

$(BIN_DIR)/go-ycsb:
	cd 3rdparty/go-ycsb && make && mv bin/go-ycsb ../../bin/.

.PHONY: benchmark-virtual
benchmark-virtual: $(BIN_DIR)/etcd $(BIN_DIR)/benchmark build-virtual .venv certs
	. .venv/bin/activate && python3 benchmark/etcd.py --virtual


.PHONY: benchmark-sgx
benchmark-sgx: $(BIN_DIR)/etcd $(BIN_DIR)/benchmark build-virtual build-sgx .venv certs
	. .venv/bin/activate && python3 benchmark/etcd.py --sgx

.PHONY: benchmark-all
benchmark-all: $(BIN_DIR)/etcd $(BIN_DIR)/benchmark build-virtual build-sgx .venv certs
	. .venv/bin/activate && python3 benchmark/etcd.py --sgx --virtual --insecure --worker-threads 0 2 4 8 --clients 1 10 100 --connections 1 10 100 --prefill-num-keys 0 10 100 1000 --prefill-value-size 10 40 160 640 --rate 10 100 1000

.venv: requirements.txt
	python3 -m venv .venv
	. .venv/bin/activate && pip3 install -r requirements.txt

.PHONY: notebook
notebook: .venv
	. .venv/bin/activate && jupyter notebook

.PHONY: execute-notebook
execute-notebook: .venv
	. .venv/bin/activate && jupyter nbconvert --execute --to notebook --inplace analysis.ipynb

.PHONY: clear-notebook
clear-notebook: .venv
	. .venv/bin/activate && jupyter nbconvert --clear-output *.ipynb

$(BIN_DIR)/cfssl:
	mkdir -p $(BIN_DIR)
	curl -s -L -o $(BIN_DIR)/cfssl https://pkg.cfssl.org/R1.2/cfssl_linux-amd64
	curl -s -L -o $(BIN_DIR)/cfssljson https://pkg.cfssl.org/R1.2/cfssljson_linux-amd64
	chmod +x $(BIN_DIR)/cfssl
	chmod +x $(BIN_DIR)/cfssljson

$(BIN_DIR)/cfssljson: $(BIN_DIR)/cfssl

.PHONY: certs
certs: $(BIN_DIR)/cfssl $(BIN_DIR)/cfssljson
	rm -rf certs
	mkdir -p certs
	cd certs && ../$(BIN_DIR)/cfssl gencert -initca ../certs-config/ca-csr.json | ../$(BIN_DIR)/cfssljson -bare ca -
	cd certs && ../$(BIN_DIR)/cfssl gencert -ca ../certs/ca.pem -ca-key ../certs/ca-key.pem -config ../certs-config/ca-config.json -profile server ../certs-config/server.json | ../$(BIN_DIR)/cfssljson -bare server -
	cd certs && ../$(BIN_DIR)/cfssl gencert -ca ../certs/ca.pem -ca-key ../certs/ca-key.pem -config ../certs-config/ca-config.json -profile client ../certs-config/client.json | ../$(BIN_DIR)/cfssljson -bare client -

.PHONY: cpplint
cpplint: $(CPP_FILES) $(H_FILES)
	cpplint --filter=-whitespace/braces,-whitespace/indent,-whitespace/comments,-whitespace/newline,-build/include_order,-build/include_subdir,-runtime/references,-runtime/indentation_namespace $(CPP_FILES) $(H_FILES)

.PHONY: clean
clean:
	rm -rf $(BUILD)
