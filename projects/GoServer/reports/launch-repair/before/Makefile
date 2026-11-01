.PHONY: build run test clean

BINARY=goserver

build:
	go build -o $(BINARY) ./cmd/demo

run: build
	./$(BINARY)

test:
	go test ./...

clean:
	rm -f $(BINARY)
