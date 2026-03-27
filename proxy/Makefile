UNAME := $(shell uname)
SRC_DIR := src

# Platform detection: macOS builds to build-mac/, Linux builds to build/
ifeq ($(UNAME), Darwin)
    BUILD_DIR := build-mac
else
    BUILD_DIR := build
endif

.PHONY: all clean rebuild

all:
	@mkdir -p $(BUILD_DIR)
	@cd $(BUILD_DIR) && cmake ../$(SRC_DIR)
	@cmake --build $(BUILD_DIR)

clean:
	rm -rf $(BUILD_DIR)

rebuild: clean all
