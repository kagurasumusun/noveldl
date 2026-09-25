# novel_core — C/C++ core build (desktop/tests).  iOS builds via project.yml.
CXX ?= g++
CC ?= gcc
CXXFLAGS ?= -std=c++17 -O2 -Wall -Wextra -Wno-unused-parameter -DNDEBUG
CPPFLAGS += -Iinclude -Isrc -DNC_HAVE_CURL -DNOVEL_CORE_SCRIPT_DIR_DEFAULT='"$(CURDIR)"'
LDLIBS += -lsqlite3 -lzstd -lcurl -lpthread

SRC = $(wildcard src/*.cpp)
OBJ = $(SRC:src/%.cpp=build/%.o)

all: build/libnovel_core.a build/novel_core_cli build/novel_core_tests

build:
	mkdir -p build

build/%.o: src/%.cpp | build
	$(CXX) $(CXXFLAGS) $(CPPFLAGS) -c $< -o $@

build/libnovel_core.a: $(OBJ)
	ar rcs $@ $^

build/novel_core_cli: tools/cli.cpp build/libnovel_core.a
	$(CXX) $(CXXFLAGS) $(CPPFLAGS) $< build/libnovel_core.a $(LDLIBS) -o $@

build/novel_core_tests: tests/test_core.cpp build/libnovel_core.a
	$(CXX) $(CXXFLAGS) $(CPPFLAGS) -UNDEBUG $< build/libnovel_core.a $(LDLIBS) -o $@

test: build/novel_core_tests
	./build/novel_core_tests

clean:
	rm -rf build

.PHONY: all test clean
