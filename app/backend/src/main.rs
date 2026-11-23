use postgres::{Client, NoTls};
use serde_json::{json, Value};
use std::io::Read;
use std::{env, thread, time::Duration};
use tiny_http::{Header, Method, Request, Response, Server};

// Baza se adresira imenom (DNS), nikad IP adresom (AO-7).
fn connect() -> Client
{
        let host = env::var("DB_HOST").unwrap_or_else(|_| "db.proj.lab".into());

        let password = env::var("DB_PASSWORD").expect("DB_PASSWORD nije postavljen");

        let conn = format!("host={host} user=app dbname=app password={password}");

        loop
        {
                match Client::connect(&conn, NoTls)
                {
                        Ok(mut c) =>
                        {
                                c.batch_execute(
                                        "CREATE TABLE IF NOT EXISTS notes (
                         id SERIAL PRIMARY KEY,
                         text TEXT NOT NULL,
                         created TIMESTAMPTZ NOT NULL DEFAULT now())",
                                )
                                .expect("kreiranje tabele");
                                return c;
                        }
                        Err(e) =>
                        {
                                eprintln!("baza nedostupna: {e}, ponovni pokusaj");
                                thread::sleep(Duration::from_secs(2));
                        }
                }
        }
}

fn reply(
        req: Request,
        status: u16,
        body: Value,
)
{
        let ct = Header::from_bytes("Content-Type", "application/json").unwrap();

        let _ = req.respond(
                Response::from_string(body.to_string())
                        .with_status_code(status)
                        .with_header(ct),
        );
}

fn main()
{
        let mut db = connect();

        let server = Server::http("0.0.0.0:8080").expect("port 8080");

        for mut req in server.incoming_requests()
        {
                // Baza se mogla ponovo kreirati (AO-10): spoji se ponovo.
                if db.is_valid(Duration::from_secs(2)).is_err()
                {
                        db = connect();
                }

                match (req.method().clone(), req.url())
                {
                        (Method::Get, "/health") => reply(req, 200, json!({"status": "ok"})),

                        (Method::Get, "/notes") => match db.query("SELECT id, text FROM notes ORDER BY id", &[])
                        {
                                Ok(rows) =>
                                {
                                        let notes: Vec<Value> = rows
                            .iter()
                            .map(|r| json!({"id": r.get::<_, i32>(0), "text": r.get::<_, String>(1)}))
                            .collect();
                                        reply(req, 200, json!(notes));
                                }
                                Err(e) => reply(req, 500, json!({"error": e.to_string()})),
                        },
                        (Method::Post, "/notes") =>
                        {
                                let mut body = String::new();
                                let _ = req.as_reader().take(10_000).read_to_string(&mut body);
                                let text = serde_json::from_str::<Value>(&body)
                                        .ok()
                                        .and_then(|v| v["text"].as_str().map(|s| s.trim().to_string()))
                                        .filter(|s| !s.is_empty());
                                match text
                                {
                                        None => reply(req, 400, json!({"error": "očekuje se {\"text\": \"...\"}"})),
                                        Some(t) => match db.execute("INSERT INTO notes (text) VALUES ($1)", &[&t])
                                        {
                                                Ok(_) => reply(req, 201, json!({"text": t})),
                                                Err(e) => reply(req, 500, json!({"error": e.to_string()})),
                                        },
                                }
                        }
                        _ => reply(req, 404, json!({"error": "nije pronađeno"})),
                }
        }
}
