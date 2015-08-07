DOCS = all-in-one.md \
       service-by-service.md

%.md: %.yml
	sh makedoc.sh $^ > $@ || rm -f $@

all: $(DOCS)

clean:
	rm -f $(DOCS)
