FROM rust:slim AS build

WORKDIR /app

# Ovisnosti u zasebnom sloju: ponovni build ne kompajlira ih ako se Cargo.* ne mijenja.
COPY Cargo.toml Cargo.lock ./

RUN mkdir src && echo 'fn main() {}' > src/main.rs && cargo build --release && rm -r src

COPY src ./src

RUN touch src/main.rs && cargo build --release

FROM debian:stable-slim

RUN apt-get update && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --no-create-home notes

COPY --from=build /app/target/release/notes /usr/local/bin/notes

USER notes

EXPOSE 8080

CMD ["notes"]
