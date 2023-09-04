# ========================================================================== #
#                                                                            #
#    pi-builder - extensible tool to build Arch Linux ARM for Raspberry Pi   #
#                 on x86_64 host using Docker.                               #
#                                                                            #
#    Copyright (C) 2018-2023  Maxim Devaev <mdevaev@gmail.com>               #
#                                                                            #
#    This program is free software: you can redistribute it and/or modify    #
#    it under the terms of the GNU General Public License as published by    #
#    the Free Software Foundation, either version 3 of the License, or       #
#    (at your option) any later version.                                     #
#                                                                            #
#    This program is distributed in the hope that it will be useful,         #
#    but WITHOUT ANY WARRANTY; without even the implied warranty of          #
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the           #
#    GNU General Public License for more details.                            #
#                                                                            #
#    You should have received a copy of the GNU General Public License       #
#    along with this program.  If not, see <https://www.gnu.org/licenses/>.  #
#                                                                            #
# ========================================================================== #


-include lib.mk

-include config.mk

export DOCKER ?= docker
export DOCKER_RUN_TTY ?= $(DOCKER) run --rm --tty
export DOCKER_RUN_INT ?= $(DOCKER) run --rm --interactive

export NC ?=

PROJECT ?= common
OS ?= arch
export BOARD ?= rpi4
export ARCH ?= arm
STAGES ?= __init__ os pikvm-repo watchdog rootdelay no-bluetooth no-audit ro ssh-keygen __cleanup__
BUILD_OPTS ?=

HOSTNAME ?= pi
LOCALE ?= en_US
TIMEZONE ?= Europe/Moscow
export REPO_URL ?= https://de3.mirror.archlinuxarm.org
PIKVM_REPO_URL ?= https://files.pikvm.org/repos/arch/
PIKVM_REPO_KEY ?= 912C773ABBD1B584

CARD ?= /dev/mmcblk0
IMAGE ?= ./$(PROJECT).$(OS)-$(BOARD)-$(ARCH).img


# =====
export __HOST_ARCH := $(subst v7l,,$(shell uname -m))
ifneq ($(__HOST_ARCH),x86_64)
ifneq ($(__HOST_ARCH),$(ARCH))
$(error Cross-arch ARM building like $(__HOST_ARCH)<->$(ARCH) is not supported)
endif
endif

__DEP_BINFMT := $(if $(call optbool,$(PASS_ENSURE_BINFMT)),,binfmt)
__DEP_TOOLBOX := $(if $(call optbool,$(PASS_ENSURE_TOOLBOX)),,toolbox)


# =====
_OS_BOARD_ARCH = $(OS)-$(BOARD)-$(ARCH)

_IMAGES_PREFIX = pi-builder.$(PROJECT).$(_OS_BOARD_ARCH)
export _TOOLBOX_IMAGE = pi-builder.$(PROJECT).toolbox

_CACHE_DIR = ./.cache
_BUILD_DIR = ./.build
_BUILT_IMAGE_CONFIG = ./.built.conf

_RESULT_ROOTFS = $(_CACHE_DIR)/$(PROJECT).$(_OS_BOARD_ARCH).rootfs
_RESULT_IMAGE = $(_CACHE_DIR)/$(PROJECT).$(_OS_BOARD_ARCH).img


# =====
define read_built_config
$(shell grep "^$(1)=" $(_BUILT_IMAGE_CONFIG) | cut -d"=" -f2)
endef

define show_running_config
$(call say,"Running configuration")
@ echo "    PROJECT    = $(PROJECT)"
@ echo "    OS         = $(OS)"
@ echo "    BOARD      = $(BOARD)"
@ echo "    ARCH       = $(ARCH)"
@ echo "    STAGES     = $(STAGES)"
@ echo "    BUILD_OPTS = $(BUILD_OPTS)"
@ echo
@ echo "    HOSTNAME       = $(HOSTNAME)"
@ echo "    LOCALE         = $(LOCALE)"
@ echo "    TIMEZONE       = $(TIMEZONE)"
@ echo "    REPO_URL       = $(REPO_URL)"
@ echo "    PIKVM_REPO_URL = $(PIKVM_REPO_URL)"
@ echo "    PIKVM_REPO_KEY = $(PIKVM_REPO_KEY)"
@ echo
@ echo "    CARD  = $(CARD)"
@ echo "    IMAGE = $(IMAGE)"
endef

define check_build
$(if $(wildcard $(_BUILT_IMAGE_CONFIG)),,$(call die,"Not built yet"))
endef


# =====
all:
	@ echo
	$(call say,"Available commands")
	@ echo "    make                     # Print this help"
	@ echo "    make rpi2|rpi3|rpi4|zero2w  # Build Arch-ARM rootfs with pre-defined config"
	@ echo "    make shell               # Run Arch-ARM shell"
	@ echo "    make toolbox             # Build the toolbox image"
	@ echo "    make binfmt              # Configure ARM binfmt on the host system"
	@ echo "    make scan                # Find all RPi devices in the local network"
	@ echo "    make clean               # Remove the generated rootfs"
	@ echo "    make image               # Make image file $(IMAGE)"
	@ echo "    make install             # Format $(CARD) and flash the filesystem"
	@ echo
	$(call show_running_config)
	@ echo


rpi2: BOARD=rpi2
rpi3: BOARD=rpi3
rpi4: BOARD=rpi4
zero2w: BOARD=zero2w
rpi2 rpi3 rpi4 zero2w: os


run: $(__DEP_BINFMT)
	$(call check_build)
	$(DOCKER_RUN_TTY) \
			$(if $(RUN_CMD),$(RUN_OPTS),--interactive) \
			--hostname $(call read_built_config,HOSTNAME) \
		$(call read_built_config,IMAGE) \
			$(if $(RUN_CMD),$(RUN_CMD),/bin/bash)


shell: override RUN_OPTS:="$(RUN_OPTS) -i"
shell: run


toolbox: $(if $(filter x86_64,$(__HOST_ARCH)),,base)
	$(call say,"Ensuring toolbox image")
	$(MAKE) -C toolbox toolbox
	$(call say,"Toolbox image is ready")


binfmt: _binfmt-host.$(__HOST_ARCH)
_binfmt-host.arm:
	@ true
_binfmt-host.aarch64:
	@ true
_binfmt-host.x86_64: $(__DEP_TOOLBOX)
	$(call say,"Ensuring $(ARCH) binfmt")
	$(DOCKER_RUN_TTY) --privileged \
		$(_TOOLBOX_IMAGE) \
			/tools/binfmt --mount $(ARCH) /usr/bin/qemu-$(ARCH)-static
	$(call say,"Binfmt $(ARCH) is ready")


scan: $(__DEP_TOOLBOX)
	$(call say,"Searching for Pis in the local network")
	$(DOCKER_RUN_TTY) --net host \
		$(_TOOLBOX_IMAGE) \
			arp-scan --localnet | grep -Pi "\s(b8:27:eb:|dc:a6:32:)" || true


# =====
os: $(__DEP_BINFMT) _buildctx
	$(call say,"Building OS")
	$(eval _image = $(_IMAGES_PREFIX)-result)
	cd $(_BUILD_DIR) && $(DOCKER) build \
			--rm \
			--tag $(_image) \
			$(if $(TAG),--tag $(TAG),) \
			$(if $(call optbool,$(NC)),--no-cache,) \
			--build-arg "BOARD=$(BOARD)" \
			--build-arg "ARCH=$(ARCH)" \
			--build-arg "LOCALE=$(LOCALE)" \
			--build-arg "TIMEZONE=$(TIMEZONE)" \
			--build-arg "REPO_URL=$(REPO_URL)" \
			--build-arg "PIKVM_REPO_URL=$(PIKVM_REPO_URL)" \
			--build-arg "PIKVM_REPO_KEY=$(PIKVM_REPO_KEY)" \
			--build-arg "REBUILD=$(shell uuidgen)" \
			$(BUILD_OPTS) \
		.
	echo "IMAGE=$(_image)" > $(_BUILT_IMAGE_CONFIG)
	echo "HOSTNAME=$(HOSTNAME)" >> $(_BUILT_IMAGE_CONFIG)
	$(call show_running_config)
	$(call say,"Build complete")


_buildctx: base qemu
	$(call say,"Assembling main Dockerfile")
	$(eval _init = $(_BUILD_DIR)/stages/__init__/Dockerfile.part)
	rm -f $(_BUILT_IMAGE_CONFIG)
	rm -rf $(_BUILD_DIR)
	mkdir -p $(_BUILD_DIR)
	#
	ln base/$(_OS_BOARD_ARCH).tgz $(_BUILD_DIR)
	test $(ARCH) == $(__HOST_ARCH) \
		|| ln qemu/qemu-$(ARCH)-static* $(_BUILD_DIR)
	#
	cp -a stages/$(OS) $(_BUILD_DIR)/stages
	sed -i -e 's|%ADD_BASE_ROOTFS_TGZ%|ADD $(_OS_BOARD_ARCH).tgz /|g' $(_init)
	test $(ARCH) != $(__HOST_ARCH) \
		&& sed -i -e 's|%COPY_QEMU_USER_STATIC%|COPY qemu-$(ARCH)-static* /usr/bin/|g' $(_init) \
		|| sed -i -e 's|%COPY_QEMU_USER_STATIC%||g' $(_init)
	for var in BOARD ARCH LOCALE TIMEZONE REPO_URL PIKVM_REPO_URL PIKVM_REPO_KEY; do \
		echo "ARG $$var" >> $(_init) \
		&& echo "ENV $$var \$$$$var" >> $(_init) \
	; done
	#
	echo -n > $(_BUILD_DIR)/Dockerfile
	for stage in $(STAGES); do \
		cat $(_BUILD_DIR)/stages/$$stage/Dockerfile.part >> $(_BUILD_DIR)/Dockerfile \
	; done
	#
	$(call cachetag,$(_BUILD_DIR))
	$(call say,"Main Dockerfile is ready")


base:
	$(call say,"Ensuring base rootfs")
	$(MAKE) -C base $(_OS_BOARD_ARCH)
	$(call say,"Base rootfs is ready")


qemu: _qemu-host.$(__HOST_ARCH)
_qemu-host.arm:
	@ true
_qemu-host.aarch64:
	@ true
_qemu-host.x86_64:
	$(call say,"Ensuring QEMU-$(ARCH)")
	$(MAKE) -C qemu qemu-$(ARCH)
	$(call say,"QEMU-$(ARCH) is ready")


# =====
define remove_cachedir
test ! -d $(_CACHE_DIR) || $(DOCKER_RUN_TTY) \
		--volume $(shell pwd):/root/dir \
		--workdir /root/dir \
	$(_TOOLBOX_IMAGE) \
		rm -rf $(shell basename $(_CACHE_DIR))
endef


clean: $(__DEP_TOOLBOX)
	$(MAKE) -C toolbox clean
	$(MAKE) -C qemu clean
	$(MAKE) -C base clean
	$(call remove_cachedir)
	rm -f $(_BUILT_IMAGE_CONFIG) $(IMAGE)
	rm -rf $(_BUILD_DIR)


clean-all: clean
	$(MAKE) -C toolbox clean-all
	$(MAKE) -C qemu clean-all
	$(MAKE) -C base clean-all


_CACHE_VOLUME_OPTS = \
	--volume $(shell pwd)/$(_CACHE_DIR):/root/$(_CACHE_DIR) \
	--workdir /root/$(_CACHE_DIR)/..


extract: $(__DEP_TOOLBOX)
	$(call check_build)
	$(call say,"Extracting image from Docker")
	$(call remove_cachedir)
	mkdir -p $(_CACHE_DIR)
	$(call cachetag,$(_CACHE_DIR))
	#
	$(DOCKER) save --output $(_RESULT_ROOTFS).tar $(call read_built_config,IMAGE)
	$(DOCKER_RUN_TTY) $(_CACHE_VOLUME_OPTS) \
		$(_TOOLBOX_IMAGE) \
			/tools/docker-extract \
				--remove-root \
				--root $(_RESULT_ROOTFS) \
				--set-hostname "$(call read_built_config,HOSTNAME)" \
				$(if $(filter x86_64,$(__HOST_ARCH)),--remove-qemu,) \
			$(_RESULT_ROOTFS).tar
	$(call say,"Extraction complete")


install: $(__DEP_TOOLBOX) extract
	$(call check_build)
	$(call say,"Installing to $(CARD)")
	cat disk.conf | $(DOCKER_RUN_INT) --privileged $(_CACHE_VOLUME_OPTS) \
		$(_TOOLBOX_IMAGE) \
			/tools/install card $(_RESULT_ROOTFS) $(CARD)
	$(call say,"Installation complete")


image: $(__DEP_TOOLBOX) extract
	$(call check_build)
	$(call say,"Installing to $(IMAGE)")
	touch $(_RESULT_IMAGE)
	cat disk.conf | $(DOCKER_RUN_INT) --privileged $(_CACHE_VOLUME_OPTS) --volume /dev:/root/dev \
		$(_TOOLBOX_IMAGE) \
			/tools/install image /root $(_RESULT_ROOTFS) $(_RESULT_IMAGE)
	mv $(_RESULT_IMAGE) $(IMAGE)
	$(call say,"Installation complete")


# =====
.PHONY: toolbox base qemu
.NOTPARALLEL:
