# novel_core — C/C++ core build (desktop/tests).  iOS builds via project.yml.
# All project includes are relative — no -I search paths for local headers.
CXX ?= g++
CC ?= gcc
CXXFLAGS ?= -std=c++17 -O2 -Wall -Wextra -Wno-unused-parameter -DNDEBUG -DNC_HAVE_ZSTD
CPPFLAGS += -DNOVEL_CORE_SCRIPT_DIR_DEFAULT='"$(CURDIR)"'
LDLIBS += -lsqlite3 -lzstd -lcurl -lpthread

SRC = $(wildcard src/*.cpp)
OBJ = $(SRC:src/%.cpp=build/%.o)

all: build/libnovel_core.a build/novel_core_cli build/novel_core_tests build/novel_core_dltest

build:
	mkdir -p build

build/%.o: src/%.cpp | build
	$(CXX) $(CXXFLAGS) $(CPPFLAGS) -c $< -o $@

build/libnovel_core.a: $(OBJ)
	ar rcs $@ $^

build/novel_core_cli: tools/cli.cpp tools/http_pipe.cpp build/libnovel_core.a
	$(CXX) $(CXXFLAGS) $(CPPFLAGS) tools/cli.cpp tools/http_pipe.cpp build/libnovel_core.a $(LDLIBS) -o $@

build/novel_core_tests: tests/test_core.cpp build/libnovel_core.a
	$(CXX) $(CXXFLAGS) $(CPPFLAGS) -UNDEBUG $< build/libnovel_core.a $(LDLIBS) -o $@

build/novel_core_dltest: tools/dltest.cpp tools/http_pipe.cpp build/libnovel_core.a
	$(CXX) $(CXXFLAGS) $(CPPFLAGS) $^ $(LDLIBS) -o $@

test: build/novel_core_tests
	./build/novel_core_tests

dltest: build/novel_core_dltest
	./build/novel_core_dltest

clean:
	rm -rf build

.PHONY: all test dltest clean
