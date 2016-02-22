# Mgmt
# Copyright (C) 2013-2016+ James Shubin and the project contributors
# Written by James Shubin <james@shubin.ca> and the project contributors
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

SHELL = /bin/bash
.PHONY: all version program path deps run race build clean test format docs rpmbuild mkdirs rpm srpm spec tar upload upload-sources upload-srpms upload-rpms copr
.SILENT: clean

SVERSION := $(shell git describe --match '[0-9]*\.[0-9]*\.[0-9]*' --tags --dirty --always)
VERSION := $(shell git describe --match '[0-9]*\.[0-9]*\.[0-9]*' --tags --abbrev=0)
PROGRAM := $(shell basename --suffix=-$(VERSION) $(notdir $(CURDIR)))
ifeq ($(VERSION),$(SVERSION))
	RELEASE = 1
else
	RELEASE = untagged
endif
ARCH = $(shell arch)
SPEC = rpmbuild/SPECS/mgmt.spec
SOURCE = rpmbuild/SOURCES/mgmt-$(VERSION).tar.bz2
SRPM = rpmbuild/SRPMS/mgmt-$(VERSION)-$(RELEASE).src.rpm
SRPM_BASE = mgmt-$(VERSION)-$(RELEASE).src.rpm
RPM = rpmbuild/RPMS/mgmt-$(VERSION)-$(RELEASE).$(ARCH).rpm
USERNAME := $(shell cat ~/.config/copr 2>/dev/null | grep username | awk -F '=' '{print $$2}' | tr -d ' ')
SERVER = 'dl.fedoraproject.org'
REMOTE_PATH = 'pub/alt/$(USERNAME)/mgmt'

all: docs

# show the current version
version:
	@echo $(VERSION)

program:
	@echo $(PROGRAM)

path:
	./misc/make-path.sh

deps:
	./misc/make-deps.sh

run:
	find -maxdepth 1 -type f -name '*.go' -not -name '*_test.go' | xargs go run -ldflags "-X main.program=$(PROGRAM) -X main.version=$(SVERSION)"

# include race flag
race:
	find -maxdepth 1 -type f -name '*.go' -not -name '*_test.go' | xargs go run -race -ldflags "-X main.program=$(PROGRAM) -X main.version=$(SVERSION)"

build: mgmt

mgmt: main.go
	@echo "Building: $(PROGRAM), version: $(SVERSION)."
	go generate
	# avoid equals sign in old golang versions eg in: -X foo=bar
	if go version | grep -qE 'go1.3|go1.4'; then \
		go build -ldflags "-X main.program $(PROGRAM) -X main.version $(SVERSION)" -o mgmt; \
	else \
		go build -ldflags "-X main.program=$(PROGRAM) -X main.version=$(SVERSION)" -o mgmt; \
	fi

clean:
	[ ! -e mgmt ] || rm mgmt
	rm -f *_stringer.go	# generated by `go generate`

test:
	./test.sh

format:
	find -type f -name '*.go' -not -path './old/*' -not -path './tmp/*' -exec gofmt -w {} \;
	find -type f -name '*.yaml' -not -path './old/*' -not -path './tmp/*' -not -path './omv.yaml' -exec ruby -e "require 'yaml'; x=YAML.load_file('{}').to_yaml.each_line.map(&:rstrip).join(10.chr)+10.chr; File.open('{}', 'w').write x" \;

docs: mgmt-documentation.pdf

mgmt-documentation.pdf: DOCUMENTATION.md
	pandoc DOCUMENTATION.md -o 'mgmt-documentation.pdf'

#
#	build aliases
#
# TODO: does making an rpm depend on making a .srpm first ?
rpm: $(SRPM) $(RPM)
	# do nothing

srpm: $(SRPM)
	# do nothing

spec: $(SPEC)
	# do nothing

tar: $(SOURCE)
	# do nothing

rpmbuild/SOURCES/: tar
rpmbuild/SRPMS/: srpm
rpmbuild/RPMS/: rpm

upload: upload-sources upload-srpms upload-rpms
	# do nothing

#
#	rpmbuild
#
$(RPM): $(SPEC) $(SOURCE)
	@echo Running rpmbuild -bb...
	rpmbuild --define '_topdir $(shell pwd)/rpmbuild' -bb $(SPEC) && \
	mv rpmbuild/RPMS/$(ARCH)/mgmt-$(VERSION)-$(RELEASE).*.rpm $(RPM)

$(SRPM): $(SPEC) $(SOURCE)
	@echo Running rpmbuild -bs...
	rpmbuild --define '_topdir $(shell pwd)/rpmbuild' -bs $(SPEC)
	# renaming is not needed because we aren't using the dist variable
	#mv rpmbuild/SRPMS/mgmt-$(VERSION)-$(RELEASE).*.src.rpm $(SRPM)

#
#	spec
#
$(SPEC): rpmbuild/ mgmt.spec.in
	@echo Running templater...
	#cat mgmt.spec.in > $(SPEC)
	sed -e s/__VERSION__/$(VERSION)/ -e s/__RELEASE__/$(RELEASE)/ < mgmt.spec.in > $(SPEC)
	# append a changelog to the .spec file
	git log --format="* %cd %aN <%aE>%n- (%h) %s%d%n" --date=local | sed -r 's/[0-9]+:[0-9]+:[0-9]+ //' >> $(SPEC)

#
#	archive
#
$(SOURCE): rpmbuild/
	@echo Running git archive...
	# use HEAD if tag doesn't exist yet, so that development is easier...
	git archive --prefix=mgmt-$(VERSION)/ -o $(SOURCE) $(VERSION) 2> /dev/null || (echo 'Warning: $(VERSION) does not exist. Using HEAD instead.' && git archive --prefix=mgmt-$(VERSION)/ -o $(SOURCE) HEAD)
	# TODO: if git archive had a --submodules flag this would easier!
	@echo Running git archive submodules...
	# i thought i would need --ignore-zeros, but it doesn't seem necessary!
	p=`pwd` && (echo .; git submodule foreach) | while read entering path; do \
		temp="$${path%\'}"; \
		temp="$${temp#\'}"; \
		path=$$temp; \
		[ "$$path" = "" ] && continue; \
		(cd $$path && git archive --prefix=mgmt-$(VERSION)/$$path/ HEAD > $$p/rpmbuild/tmp.tar && tar --concatenate --file=$$p/$(SOURCE) $$p/rpmbuild/tmp.tar && rm $$p/rpmbuild/tmp.tar); \
	done

# TODO: ensure that each sub directory exists
rpmbuild/:
	mkdir -p rpmbuild/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}

mkdirs:
	mkdir -p rpmbuild/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}

#
#	sha256sum
#
rpmbuild/SOURCES/SHA256SUMS: rpmbuild/SOURCES/ $(SOURCE)
	@echo Running SOURCES sha256sum...
	cd rpmbuild/SOURCES/ && sha256sum *.tar.bz2 > SHA256SUMS; cd -

rpmbuild/SRPMS/SHA256SUMS: rpmbuild/SRPMS/ $(SRPM)
	@echo Running SRPMS sha256sum...
	cd rpmbuild/SRPMS/ && sha256sum *src.rpm > SHA256SUMS; cd -

rpmbuild/RPMS/SHA256SUMS: rpmbuild/RPMS/ $(RPM)
	@echo Running RPMS sha256sum...
	cd rpmbuild/RPMS/ && sha256sum *.rpm > SHA256SUMS; cd -

#
#	gpg
#
rpmbuild/SOURCES/SHA256SUMS.asc: rpmbuild/SOURCES/SHA256SUMS
	@echo Running SOURCES gpg...
	# the --yes forces an overwrite of the SHA256SUMS.asc if necessary
	gpg2 --yes --clearsign rpmbuild/SOURCES/SHA256SUMS

rpmbuild/SRPMS/SHA256SUMS.asc: rpmbuild/SRPMS/SHA256SUMS
	@echo Running SRPMS gpg...
	gpg2 --yes --clearsign rpmbuild/SRPMS/SHA256SUMS

rpmbuild/RPMS/SHA256SUMS.asc: rpmbuild/RPMS/SHA256SUMS
	@echo Running RPMS gpg...
	gpg2 --yes --clearsign rpmbuild/RPMS/SHA256SUMS

#
#	upload
#
# upload to public server
upload-sources: rpmbuild/SOURCES/ rpmbuild/SOURCES/SHA256SUMS rpmbuild/SOURCES/SHA256SUMS.asc
	if [ "`cat rpmbuild/SOURCES/SHA256SUMS`" != "`ssh $(SERVER) 'cd $(REMOTE_PATH)/SOURCES/ && cat SHA256SUMS'`" ]; then \
		echo Running SOURCES upload...; \
		rsync -avz rpmbuild/SOURCES/ $(SERVER):$(REMOTE_PATH)/SOURCES/; \
	fi

upload-srpms: rpmbuild/SRPMS/ rpmbuild/SRPMS/SHA256SUMS rpmbuild/SRPMS/SHA256SUMS.asc
	if [ "`cat rpmbuild/SRPMS/SHA256SUMS`" != "`ssh $(SERVER) 'cd $(REMOTE_PATH)/SRPMS/ && cat SHA256SUMS'`" ]; then \
		echo Running SRPMS upload...; \
		rsync -avz rpmbuild/SRPMS/ $(SERVER):$(REMOTE_PATH)/SRPMS/; \
	fi

upload-rpms: rpmbuild/RPMS/ rpmbuild/RPMS/SHA256SUMS rpmbuild/RPMS/SHA256SUMS.asc
	if [ "`cat rpmbuild/RPMS/SHA256SUMS`" != "`ssh $(SERVER) 'cd $(REMOTE_PATH)/RPMS/ && cat SHA256SUMS'`" ]; then \
		echo Running RPMS upload...; \
		rsync -avz --prune-empty-dirs rpmbuild/RPMS/ $(SERVER):$(REMOTE_PATH)/RPMS/; \
	fi

#
#	copr build
#
copr: upload-srpms
	./misc/copr-build.py https://$(SERVER)/$(REMOTE_PATH)/SRPMS/$(SRPM_BASE)

# vim: ts=8
