DOCS = osp-6-7-upgrade.md

%.md: %.yml
	sh makedoc.sh $^ > $@ || rm -f $@

all: $(DOCS)

