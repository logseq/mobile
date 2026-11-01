// Calculator grammar and formatting mirror logseq/logseq's calc.cljc and calc.bnf.
// BigNumber is the same decimal arithmetic library used by the master calculator.
const calculatorConstants = {
    PI: new BigNumber("3.14159265358979323846"),
    E: new BigNumber("2.71828182845904523536")
};

function calculatorExpression(source, variables) {
    let position = 0;
    const skip = () => { while (/\s/.test(source[position] || "") && position < source.length) position++; };
    const consume = (token) => {
        skip();
        if (!source.startsWith(token, position)) return false;
        position += token.length;
        return true;
    };
    const match = (pattern) => {
        skip();
        const found = pattern.exec(source.slice(position));
        if (!found) return null;
        position += found[0].length;
        return found;
    };
    function primary() {
        if (consume("(")) {
            const value = sum();
            if (!consume(")")) throw Error("Expected closing parenthesis");
            return value;
        }
        const mixed = match(/^(\d+)\s+(\d+)\/(\d+)/);
        if (mixed) return new BigNumber(mixed[2]).dividedBy(mixed[3]).plus(mixed[1]);
        const number = match(/^(?:0x(?:[\da-f]+(?:,[\da-f]+)*(?:\.[\da-f]*)?|[\da-f]*\.[\da-f]+)|0o(?:[0-7]+(?:,[0-7]+)*(?:\.[0-7]*)?|[0-7]*\.[0-7]+)|0b(?:[01]+(?:,[01]+)*(?:\.[01]*)?|[01]*\.[01]+)|\d*\.?\d+[eE][+-]?\d+|\d+(?:,\d+)*(?:\.\d*)?|\d*\.\d+)/i);
        if (number) {
            const value = new BigNumber(number[0].replace(/,/g, ""));
            return consume("%") ? value.dividedBy(100) : value;
        }
        const identifier = match(/^_*[a-zA-Z]+[_a-zA-Z0-9]*/);
        if (!identifier) throw Error("Expected a number or variable");
        const name = identifier[0];
        if (consume("(")) {
            const value = sum();
            if (!consume(")")) throw Error("Expected closing parenthesis");
            if (name === "abs") return value.abs();
            if (name === "sqrt") return value.sqrt();
            const functions = {log: Math.log10, ln: Math.log, exp: Math.exp,
                sin: Math.sin, cos: Math.cos, tan: Math.tan,
                asin: Math.asin, acos: Math.acos, atan: Math.atan};
            if (!Object.hasOwn(functions, name)) throw Error("Unknown function");
            return new BigNumber(functions[name](value.toNumber()));
        }
        const value = Object.hasOwn(calculatorConstants, name) ? calculatorConstants[name] : variables[name];
        if (!(value instanceof BigNumber)) throw Error("Unknown variable");
        return value;
    }
    function power() {
        if (consume("-")) return power().negated();
        let value = primary();
        if (consume("^")) {
            const exponent = power();
            return exponent.isInteger() ? value.exponentiatedBy(exponent)
                : new BigNumber(Math.pow(value.toNumber(), exponent.toNumber()));
        }
        if (consume("!")) {
            if (!value.isInteger() || !value.isPositive() || !value.isLessThan(254)) return new BigNumber(NaN);
            const n = value.toNumber();
            value = new BigNumber(1);
            for (let i = 2; i <= n; i++) value = value.multipliedBy(i);
        }
        return value;
    }
    function product() {
        let value = power();
        for (;;) {
            if (consume("*")) value = value.multipliedBy(power());
            else if (consume("/")) value = value.dividedBy(power());
            else if (match(/^mod\b/)) value = value.modulo(power());
            else return value;
        }
    }
    function sum() {
        let value = product();
        for (;;) {
            if (consume("+")) value = value.plus(product());
            else if (consume("-")) value = value.minus(product());
            else return value;
        }
    }
    const value = sum();
    skip();
    if (position !== source.length) throw Error("Unexpected input");
    return value;
}

function calculatorNormal(value, settings) {
    const precision = settings.precision === undefined ? 21 : settings.precision;
    const display = value.precision(precision);
    return display.e < precision && display.shiftedBy(precision + 1).isInteger()
        ? display.toFixed() : display.toExponential();
}

function calculatorFormat(value, settings) {
    if (value === undefined) return "";
    if (!(value instanceof BigNumber)) return "Error";
    const base = {hex: 16, oct: 8, bin: 2}[settings.base];
    if (base) return (value.s < 0 ? "-" : "") + {2: "0b", 8: "0o", 16: "0x"}[base] + value.abs().toString(base);
    if (settings.mode === "fix") {
        const magnitude = value.abs();
        const canFix = value.isZero() || (magnitude.isGreaterThanOrEqualTo(new BigNumber(0.5).shiftedBy(-settings.places))
            && magnitude.isLessThan("1e21"));
        return canFix ? value.toFixed(settings.places) : value.toExponential(settings.places);
    }
    if (settings.mode === "sci") return value.toExponential(settings.places);
    if (settings.mode === "frac") {
        const [numerator, denominator] = value.toFraction(settings.maxDenominator === undefined ? 4095 : settings.maxDenominator);
        const delta = numerator.dividedBy(denominator).minus(value);
        if (delta.isZero() || delta.e < -16) {
            if (denominator.isGreaterThan(1)) {
                const whole = numerator.dividedToIntegerBy(denominator);
                return settings.improper || whole.isZero() ? numerator + "/" + denominator
                    : whole + " " + numerator.modulo(denominator).abs() + "/" + denominator;
            }
            return calculatorNormal(numerator, settings);
        }
    }
    return calculatorNormal(value, settings);
}

function calculatorDirective(source, settings) {
    const format = /^:(?:fmt|format)\s+([a-zA-Z]+)\s*(\d+)?$/.exec(source);
    if (format) {
        const name = format[1].toLowerCase();
        const digits = format[2] === undefined ? undefined : Number(format[2]);
        if (/^fix(?:ed)?$/.test(name) && digits !== undefined) {
            settings.mode = "fix"; settings.places = digits;
        } else if (/^sci(?:entific)?$/.test(name)) {
            settings.mode = "sci"; settings.places = digits;
        } else if (/^norm(?:al)?$/.test(name)) {
            delete settings.mode; delete settings.places; settings.precision = digits;
        } else if (/^frac(?:tions?)?$/.test(name) || /^imp(?:roper)?$/.test(name)) {
            settings.mode = "frac"; settings.maxDenominator = digits; settings.improper = name.startsWith("imp");
        } else throw Error("Invalid format directive");
        return;
    }
    const base = /^:(hex(?:adecimal)?|dec(?:imal)?|oct(?:al)?|bin(?:ary)?)$/i.exec(source);
    if (!base) throw Error("Invalid calculator directive");
    settings.base = base[1].toLowerCase().slice(0, 3);
}

globalThis.logseqCalculatorLines = function(source) {
    const variables = Object.create(null), settings = {};
    return JSON.stringify(source.split(/\r?\n/).map(line => {
        const expression = line.split("#", 1)[0].trim();
        if (!expression) return "";
        try {
            let value;
            if (expression.startsWith(":")) {
                calculatorDirective(expression, settings);
                value = variables.last;
            } else {
                const assignment = /^(_*[a-zA-Z]+[_a-zA-Z0-9]*)\s*=\s*(.+)$/.exec(expression);
                value = calculatorExpression(assignment ? assignment[2] : expression, variables);
                if (assignment) {
                    if (Object.hasOwn(calculatorConstants, assignment[1])) throw Error("Cannot redefine a constant");
                    variables[assignment[1]] = value;
                }
            }
            if (value !== undefined) variables.last = value;
            return calculatorFormat(value, settings);
        } catch (_) {
            variables.last = null;
            return "Error";
        }
    }));
};
