//! A tiny predicate language for achievement triggers (SPEC 7.6): field reads,
//! numbers, strings, booleans, comparisons, + - * /, and && || !.
//! No script engine; missing fields read as Null (0 / false / "").

#[derive(Debug, Clone, PartialEq)]
pub enum Val {
    Num(f64),
    Bool(bool),
    Str(String),
    Null,
}

impl Val {
    pub fn num(&self) -> f64 {
        match self {
            Val::Num(n) => *n,
            Val::Bool(b) => *b as u8 as f64,
            Val::Str(_) | Val::Null => 0.0,
        }
    }

    pub fn truthy(&self) -> bool {
        match self {
            Val::Num(n) => *n != 0.0,
            Val::Bool(b) => *b,
            Val::Str(s) => !s.is_empty(),
            Val::Null => false,
        }
    }
}

impl From<f64> for Val {
    fn from(n: f64) -> Val {
        Val::Num(n)
    }
}
impl From<u32> for Val {
    fn from(n: u32) -> Val {
        Val::Num(n as f64)
    }
}
impl From<bool> for Val {
    fn from(b: bool) -> Val {
        Val::Bool(b)
    }
}
impl From<&str> for Val {
    fn from(s: &str) -> Val {
        Val::Str(s.to_string())
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Op {
    Or,
    And,
    Eq,
    Ne,
    Lt,
    Le,
    Gt,
    Ge,
    Add,
    Sub,
    Mul,
    Div,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Expr {
    Lit(Val),
    Var(String),
    Not(Box<Expr>),
    Neg(Box<Expr>),
    Bin(Op, Box<Expr>, Box<Expr>),
}

#[derive(Debug, Clone, PartialEq)]
enum Tok {
    Num(f64),
    Str(String),
    Ident(String),
    Op(&'static str),
    LParen,
    RParen,
}

fn lex(src: &str) -> Result<Vec<Tok>, String> {
    let c: Vec<char> = src.chars().collect();
    let mut out = Vec::new();
    let mut i = 0;
    while i < c.len() {
        let ch = c[i];
        if ch.is_whitespace() {
            i += 1;
        } else if ch.is_ascii_digit() {
            let s = i;
            while i < c.len() && (c[i].is_ascii_digit() || c[i] == '.') {
                i += 1;
            }
            let t: String = c[s..i].iter().collect();
            out.push(Tok::Num(t.parse().map_err(|_| format!("bad number {t}"))?));
        } else if ch.is_alphabetic() || ch == '_' {
            let s = i;
            while i < c.len() && (c[i].is_alphanumeric() || c[i] == '_' || c[i] == '.') {
                i += 1;
            }
            out.push(Tok::Ident(c[s..i].iter().collect()));
        } else if ch == '"' {
            let s = i + 1;
            i += 1;
            while i < c.len() && c[i] != '"' {
                i += 1;
            }
            if i >= c.len() {
                return Err("unterminated string".into());
            }
            out.push(Tok::Str(c[s..i].iter().collect()));
            i += 1;
        } else if ch == '(' {
            out.push(Tok::LParen);
            i += 1;
        } else if ch == ')' {
            out.push(Tok::RParen);
            i += 1;
        } else {
            let two: String = c[i..(i + 2).min(c.len())].iter().collect();
            let op = ["||", "&&", "==", "!=", "<=", ">="].into_iter().find(|o| *o == two);
            if let Some(o) = op {
                out.push(Tok::Op(o));
                i += 2;
            } else {
                let o = match ch {
                    '<' => "<",
                    '>' => ">",
                    '+' => "+",
                    '-' => "-",
                    '*' => "*",
                    '/' => "/",
                    '!' => "!",
                    _ => return Err(format!("unexpected {ch:?}")),
                };
                out.push(Tok::Op(o));
                i += 1;
            }
        }
    }
    Ok(out)
}

struct Parser {
    toks: Vec<Tok>,
    pos: usize,
}

impl Parser {
    fn peek_op(&self) -> Option<&'static str> {
        match self.toks.get(self.pos) {
            Some(Tok::Op(o)) => Some(o),
            _ => None,
        }
    }

    fn binary(&mut self, level: usize) -> Result<Expr, String> {
        const LEVELS: [&[(&str, Op)]; 5] = [
            &[("||", Op::Or)],
            &[("&&", Op::And)],
            &[("==", Op::Eq), ("!=", Op::Ne), ("<=", Op::Le), (">=", Op::Ge), ("<", Op::Lt), (">", Op::Gt)],
            &[("+", Op::Add), ("-", Op::Sub)],
            &[("*", Op::Mul), ("/", Op::Div)],
        ];
        if level == LEVELS.len() {
            return self.unary();
        }
        let mut lhs = self.binary(level + 1)?;
        while let Some(o) = self.peek_op() {
            let Some((_, op)) = LEVELS[level].iter().find(|(s, _)| *s == o) else { break };
            self.pos += 1;
            let rhs = self.binary(level + 1)?;
            lhs = Expr::Bin(*op, Box::new(lhs), Box::new(rhs));
        }
        Ok(lhs)
    }

    fn unary(&mut self) -> Result<Expr, String> {
        match self.peek_op() {
            Some("!") => {
                self.pos += 1;
                Ok(Expr::Not(Box::new(self.unary()?)))
            }
            Some("-") => {
                self.pos += 1;
                Ok(Expr::Neg(Box::new(self.unary()?)))
            }
            _ => self.atom(),
        }
    }

    fn atom(&mut self) -> Result<Expr, String> {
        let t = self.toks.get(self.pos).cloned().ok_or("unexpected end")?;
        self.pos += 1;
        Ok(match t {
            Tok::Num(n) => Expr::Lit(Val::Num(n)),
            Tok::Str(s) => Expr::Lit(Val::Str(s)),
            Tok::Ident(s) if s == "true" => Expr::Lit(Val::Bool(true)),
            Tok::Ident(s) if s == "false" => Expr::Lit(Val::Bool(false)),
            Tok::Ident(s) => Expr::Var(s),
            Tok::LParen => {
                let e = self.binary(0)?;
                if self.toks.get(self.pos) != Some(&Tok::RParen) {
                    return Err("missing )".into());
                }
                self.pos += 1;
                e
            }
            t => return Err(format!("unexpected {t:?}")),
        })
    }
}

pub fn parse(src: &str) -> Result<Expr, String> {
    let mut p = Parser { toks: lex(src)?, pos: 0 };
    let e = p.binary(0)?;
    if p.pos != p.toks.len() {
        return Err(format!("trailing input in {src:?}"));
    }
    Ok(e)
}

impl Expr {
    pub fn eval(&self, get: &dyn Fn(&str) -> Val) -> Val {
        match self {
            Expr::Lit(v) => v.clone(),
            Expr::Var(name) => get(name),
            Expr::Not(e) => Val::Bool(!e.eval(get).truthy()),
            Expr::Neg(e) => Val::Num(-e.eval(get).num()),
            Expr::Bin(op, a, b) => {
                let x = a.eval(get);
                // Short-circuit the logical operators.
                match op {
                    Op::And => return Val::Bool(x.truthy() && b.eval(get).truthy()),
                    Op::Or => return Val::Bool(x.truthy() || b.eval(get).truthy()),
                    _ => {}
                }
                let y = b.eval(get);
                match op {
                    Op::Eq | Op::Ne => {
                        let eq = match (&x, &y) {
                            (Val::Str(s), Val::Str(t)) => s == t,
                            (Val::Str(_), _) | (_, Val::Str(_)) => false,
                            _ => x.num() == y.num(),
                        };
                        Val::Bool(if *op == Op::Eq { eq } else { !eq })
                    }
                    Op::Lt => Val::Bool(x.num() < y.num()),
                    Op::Le => Val::Bool(x.num() <= y.num()),
                    Op::Gt => Val::Bool(x.num() > y.num()),
                    Op::Ge => Val::Bool(x.num() >= y.num()),
                    Op::Add => Val::Num(x.num() + y.num()),
                    Op::Sub => Val::Num(x.num() - y.num()),
                    Op::Mul => Val::Num(x.num() * y.num()),
                    Op::Div => {
                        let d = y.num();
                        Val::Num(if d == 0.0 { 0.0 } else { x.num() / d })
                    }
                    Op::And | Op::Or => unreachable!(),
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ev(src: &str) -> Val {
        let get = |k: &str| match k {
            "lines_added" => Val::Num(10.0),
            "lines_removed" => Val::Num(600.0),
            "git_action" => Val::Str("commit".into()),
            "test_passed" => Val::Bool(true),
            "session.files" => Val::Num(3.0),
            _ => Val::Null,
        };
        parse(src).unwrap().eval(&get)
    }

    #[test]
    fn spec_example() {
        assert_eq!(ev("lines_removed - lines_added >= 500"), Val::Bool(true));
    }

    #[test]
    fn precedence_and_logic() {
        assert_eq!(ev("1 + 2 * 3"), Val::Num(7.0));
        assert_eq!(ev("(1 + 2) * 3"), Val::Num(9.0));
        assert_eq!(ev("git_action == \"commit\" && test_passed"), Val::Bool(true));
        assert_eq!(ev("git_action == \"merge\" || session.files > 2"), Val::Bool(true));
        assert_eq!(ev("!test_passed"), Val::Bool(false));
        assert_eq!(ev("-lines_added < 0"), Val::Bool(true));
        assert_eq!(ev("missing >= 1"), Val::Bool(false));
        assert_eq!(ev("missing == 0"), Val::Bool(true));
        assert_eq!(ev("1 / 0"), Val::Num(0.0));
    }

    #[test]
    fn errors() {
        assert!(parse("1 +").is_err());
        assert!(parse("(1").is_err());
        assert!(parse("a b").is_err());
        assert!(parse("a # b").is_err());
        assert!(parse("\"open").is_err());
    }
}
