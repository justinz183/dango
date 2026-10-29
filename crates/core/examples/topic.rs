//! Prints the topic of each line on stdin (checking the classifier):
//! `echo 'prompt' | cargo run -q -p shadowcorp-core --example topic`
use std::io::BufRead;
fn main() {
    for line in std::io::stdin().lock().lines().map_while(Result::ok) {
        println!("{}\t{}", shadowcorp_core::occupation::topic(&line).unwrap_or("-"), line);
    }
}
