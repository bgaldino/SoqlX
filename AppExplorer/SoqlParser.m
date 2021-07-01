// Copyright (c) 2021 Simon Fell
//
// Permission is hereby granted, free of charge, to any person obtaining a
// copy of this software and associated documentation files (the "Software"),
// to deal in the Software without restriction, including without limitation
// the rights to use, copy, modify, merge, publish, distribute, sublicense,
// and/or sell copies of the Software, and to permit persons to whom the
// Software is furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included
// in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
// OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.
//

#import "SoqlParser.h"
#import "ZKParserFactory.h"
#import "SoqlToken.h"
#import "Completion.h"

const NSString *KeyTokens = @"tokens";
const NSString *KeySoqlText = @"soql";

NSString *KeyPosition = @"Position";
NSString *KeyCompletions = @"Completions";


@interface SoqlParser()
@property (strong,nonatomic) ZKBaseParser *parser;
@end

@interface ZKParserFactory(SoqlX)
// constructs a seq parser for each whitespace separated token, e.g. given input "NULLS LAST" will generate
// seq:"NULLS", ws, "LAST".
-(ZKBaseParser*)tokenSeq:(NSString *)t type:(TokenType)type;
// TokenSeq with a type of TTKeyword
-(ZKBaseParser*)tokenSeq:(NSString *)t;
// Completions can be nil, in which case they'll be autogenerated from the supplied token type & tokens.
-(ZKBaseParser*)oneOfTokens:(NSArray<NSString*>*)tokens type:(TokenType)type completions:(NSArray<Completion*>*)completions addToContext:(BOOL)addToContext;

-(ZKBaseParser*)ident;
-(ZKBaseParser*)literalValue;
-(ZKBaseParser*)withDataCategory;

@end

@implementation SoqlParser

-(instancetype)init {
    self = [super init];
    self.parser = [self buildParser:nil];
    return self;
}

-(void)setDebugOutputTo:(NSString*)filename {
    self.parser = [self buildParser:filename];
}

-(NSArray<Token*>*)parse:(NSString *)input error:(NSError**)err {
    NSDictionary *ctx = @{KeyTokens: [Tokens new],
                          KeySoqlText:input,
    };
    ZKParsingState *state = [ZKParsingState withInput:input];
    state.userContext = ctx;
    [state parse:self.parser error:err];
    return ctx[KeyTokens];
}

-(ZKBaseParser*)buildParser:(NSString*)debugFilename {
    ZKParserFactory *f = [ZKParserFactory new];
    if (debugFilename.length > 0) {
        f.debugFile = debugFilename;
    }
    f.defaultCaseSensitivity = ZKCaseInsensitive;
    
    ZKBaseParser* ws = [f characters:[NSCharacterSet whitespaceAndNewlineCharacterSet] name:@"whitespace" min:1];
    f.whitespace = ws;
    ZKBaseParser* maybeWs = [f characters:[NSCharacterSet whitespaceAndNewlineCharacterSet] name:@"whitespace" min:0];
    f.maybeWhitespace = maybeWs;
    ZKBaseParser* cut = [f cut];
    
    ZKBaseParser* commaSep = [f seq:@[maybeWs, [f eq:@","], maybeWs]];
    ZKBaseParser *ident = [f ident];
    
    // SELECT LIST
    ZKParserRef *selectStmt = [f parserRef];

    // USING is not in the doc, but appears to not be allowed
    // ORDER & OFFSET are issues for our parser, but not the sfdc one.
    NSSet<NSString*> *keywords = [NSSet setWithArray:[@"ORDER OFFSET USING AND ASC DESC EXCLUDES FIRST FROM GROUP HAVING IN INCLUDES LAST LIKE LIMIT NOT NULL NULLS OR SELECT WHERE WITH" componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]];
    ZKBaseParser *aliasOnly = [f zeroOrOne:[f onMatch:[f seq:@[ws, ident]] perform:pick(1)]];
    ZKBaseParser *alias = [f fromBlock:^ZKParserResult *(ZKParsingState *input) {
        NSInteger start = input.pos;
        ZKParserResult *r = [aliasOnly parse:input];
        if (r.val != [NSNull null]) {
            NSString *txt = [r.val uppercaseString];
            if ([keywords containsObject:txt]) {
                [input moveTo:start];
                [input clearError];
                return [ZKParserResult result:[NSNull null] ctx:input.userContext loc:r.loc];
            }
            Token *t = [Token txt:r.userContext[KeySoqlText] loc:r.loc];
            t.type = TTAliasDecl;
            [r.userContext[KeyTokens] addToken:t];
            r.val = t;
        }
        return r;
    }];
    ZKBaseParser* fieldPath = [f onMatch:[f oneOrMore:ident separator:[f eq:@"."]] perform:^ZKParserResult *(ZKParserResult *r) {
        Token *t = [Token txt:r.userContext[KeySoqlText] loc:r.loc];
        t.type = TTFieldPath;
        t.value = r.childVals;
        [r.userContext[KeyTokens] addToken:t];
        r.val = t;
        return r;
    }];
    fieldPath.debugName = @"fieldPath";
    
    ZKBaseParser* fieldAndAlias = [f seq:@[fieldPath, alias]];
    fieldAndAlias.debugName = @"field";
    
    ZKBaseParser *literalValue = [f literalValue];

    ZKParserRef *fieldOrFunc = [f parserRef];
    ZKBaseParser* func = [f onMatch:[f seq:@[ident,
                              maybeWs,
                              [f eq:@"("],
                              cut,
                              maybeWs,
                              [f zeroOrMore:[f firstOf:@[fieldOrFunc,literalValue]] separator:commaSep],
                              maybeWs,
                              [f eq:@")"],
                              alias
                            ]] perform:^ZKParserResult*(ZKParserResult*r) {
        Token *fn = [Token txt:r.userContext[KeySoqlText] loc:[[r child:0] loc]];
        fn.type = TTFunc;
        Tokens *tk = r.userContext[KeyTokens];
        fn.value = [tk cutPositionRange:NSUnionRange([[r child:0] loc], [[r child:7] loc])]; // doesn't include alias
        [tk addToken:fn];
        return r;
    }];
    func.debugName = @"func";
    // TODO, add onError handler that changes the error message to expected field, func or literal value. needs errorCodes sorting out
    
    fieldOrFunc.parser = [f firstOf:@[func, fieldAndAlias]];
    
    ZKBaseParser *nestedSelectStmt = [f onMatch:[f seq:@[[f eq:@"("], selectStmt, [f eq:@")"]]] perform:^ZKParserResult*(ZKParserResult*r) {
        Token *t = [Token txt:r.userContext[KeySoqlText] loc:r.loc];
        t.type = TTChildSelect;
        [r.userContext[KeyTokens] addToken:t];
        // TODO, cut child tokens out into value here?
        r.val = t;
        return r;
    }];
    nestedSelectStmt.debugName = @"NestedSelect";
    ZKBaseParser *typeOfWhen = [f onMatch:[f seq:@[[f tokenSeq:@"WHEN"], cut, ws, ident, ws, [f tokenSeq:@"THEN"], ws,
                                         [f oneOrMore:fieldPath separator:commaSep]]] perform:^ZKParserResult *(ZKParserResult *r) {
        Token *t = [Token txt:r.userContext[KeySoqlText] loc:[[r child:3] loc]];
        t.type = TTSObject;
        [r.userContext[KeyTokens] addToken:t];
        return r;
    }];
    ZKBaseParser *typeOfElse = [f seq:@[[f tokenSeq:@"ELSE"], ws, [f oneOrMore:fieldPath separator:commaSep]]];
    ZKBaseParser *typeofRel = [f onMatch:ident perform:^ZKParserResult *(ZKParserResult *r) {
        Token *t = [Token txt:r.userContext[KeySoqlText] loc:r.loc];
        t.type = TTRelationship;
        [r.userContext[KeyTokens] addToken:t];
        return r;
    }];
    ZKBaseParser *typeOf = [f onMatch:[f seq:@[
                                [f tokenSeq:@"TYPEOF"], cut, ws,
                                typeofRel, ws,
                                [f oneOrMore:typeOfWhen separator:ws], maybeWs,
                                [f zeroOrOne:typeOfElse], maybeWs,
                                [f tokenSeq:@"END"]]] perform:^ZKParserResult *(ZKParserResult *r) {
        Token *t = [Token txt:r.userContext[KeySoqlText] loc:r.loc];
        t.type = TTTypeOf;
        [r.userContext[KeyTokens] addToken:t];
        return r;
    }];
    typeOf.debugName = @"typeOf";
    typeOfWhen.debugName = @"typeOfWhen";
    typeOfElse.debugName = @"typeOfElse";
    
    ZKBaseParser* selectExprs = [f oneOrMore:[f firstOf:@[func, typeOf, fieldAndAlias, nestedSelectStmt]] separator:commaSep];
    selectExprs.debugName = @"selectExprs";

    /// FROM
    ZKBaseParser *objectRef = [f onMatch:[f seq:@[ident, alias]] perform:^ZKParserResult *(ZKParserResult *r) {
        Token *t = [Token txt:r.userContext[KeySoqlText] loc:[[r child:0] loc]];
        t.type = TTSObject;
        [r.userContext[KeyTokens] addToken:t];
        // alias was already taken care of by the alias parser.
        return r;
    }];
    ZKBaseParser *objectRefs = [f onMatch:[f seq:@[objectRef, [f zeroOrOne:
                                         [f onMatch:[f seq:@[commaSep, [f oneOrMore:fieldAndAlias separator:commaSep]]] perform:pick(1)]]]]
                          perform:^ZKParserResult *(ZKParserResult*r) {
        
        // The tokens generated by fieldAndAlias have the wrong type in this case.
        if (![r childIsNull:1]) {
            // rels is the array of fieldAndAliases
            NSArray<ZKParserResult*>* rels = [[[r child:1] val] valueForKey:@"val"];
            for (NSArray<ZKParserResult*>*fieldAndAlias in rels) {
                // each fieldAndAlias has 2 children, one for field & one for alias.
                if ([fieldAndAlias[0].val isKindOfClass:[Token class]]) {
                    Token *t = (Token*)fieldAndAlias[0].val;
                    t.type = TTSObjectRelation;
                }
            }
        }
        return r;
    }];
    
    /// WHERE
    NSArray<Completion*>* opCompletions = [Completion completions:@[@"<",@"<=",@">",@">=", @"=", @"!=", @"LIKE",@"INCLUDES",@"EXCLUDES",@"IN"] type:TTOperator];
    Completion *compNotIn = [Completion txt:@"NOT IN" type:TTOperator];
    compNotIn.nonFinalInsertionText = @"NOT_IN";
    compNotIn.finalInsertionText = @"NOT IN";
    opCompletions = [opCompletions arrayByAddingObject:compNotIn];
    ZKBaseParser *operator  = [f oneOfTokens:@[@"<",@"<=",@">",@">=",@"=",@"!=",@"LIKE"] type:TTOperator completions:opCompletions addToContext:TRUE];
    ZKBaseParser *opIncExcl = [f oneOfTokens:@[@"INCLUDES",@"EXCLUDES"] type:TTOperator completions:opCompletions addToContext:TRUE];
    ZKBaseParser *inOrNotIn = [f oneOf:@[[f tokenSeq:@"IN" type:TTOperator], [f tokenSeq:@"NOT IN" type:TTOperator]]];
    ZKBaseParser *opInNotIn = [f fromBlock:^ZKParserResult *(ZKParsingState *input) {
        ZKParserResult *r = [inOrNotIn parse:input];
        if (!input.hasError) {
            [[r.val completions] addObjectsFromArray:[Completion completions:@[@"IN",@"NOT IN"] type:TTOperator]];
        } else {
            ZKParserError *e = [input error:[NSString stringWithFormat:@"expecting one of %@ at position %lu",
                          [[opCompletions valueForKey:@"displayText"] componentsJoinedByString:@","], input.pos+1]];
            e.userInfo = [NSMutableDictionary dictionaryWithObject:opCompletions forKey:KeyCompletions];
        }
        return r;
    }];
    opInNotIn.debugName=@"In/NotIn";
    ZKBaseParser *literalList = [f seq:@[[f eq:@"("], maybeWs,
                                        [f oneOrMore:literalValue separator:commaSep],
                                         maybeWs, [f eq:@")"]]];

    ZKBaseParser *semiJoinValues = [f onMatch:[f firstOf:@[nestedSelectStmt, literalList]] perform:^ZKParserResult *(ZKParserResult *r) {
        if ([r.val isKindOfClass:[Token class]]) {
            Token *t = r.val;
            if (t.type == TTChildSelect) {
                t.type = TTSemiJoinSelect;
            }
        }
        return r;
    }];
    ZKBaseParser *operatorRHS = [f firstOf:@[
        [f seq:@[operator, cut, maybeWs, literalValue]],
        [f seq:@[opIncExcl, cut, maybeWs, literalList]],
        [f seq:@[opInNotIn, cut, maybeWs, semiJoinValues]]]];

    ZKBaseParser *baseExpr = [f seq:@[fieldOrFunc, maybeWs, operatorRHS]];

    // use parserRef so that we can set up the recursive decent for x op y and (y op z or z op t)
    // be careful not to use oneOf with it as that will recurse infinitly because it checks all branches.
    ZKParserRef *exprList = [f parserRef];
    ZKBaseParser *parensExpr = [f onMatch:[f seq:@[[f eq:@"("], maybeWs, exprList, maybeWs, [f eq:@")"]]] perform:pick(2)];

    // we don't want to add the and/or token to context as soon as possible because OR is ambigious with ORDER BY. we need to wait til we pass
    // the whitespace tests.
    ZKBaseParser *andOrToken = [f oneOfTokens:@[@"AND",@"OR"] type:TTOperator completions:nil addToContext:FALSE];
    ZKBaseParser *andOr = [f onMatch:[f seq:@[maybeWs, andOrToken, ws]] perform:^ZKParserResult*(ZKParserResult*r) {
        Token *t = [[r child:1] val];
        [r.userContext[KeyTokens] addToken:t];
        return r;
    }];
    ZKBaseParser *not = [f seq:@[[f tokenSeq:@"NOT" type:TTOperator], maybeWs]];
    exprList.parser = [f seq:@[[f zeroOrOne:not],[f firstOf:@[parensExpr, baseExpr]], [f zeroOrOne:[f seq:@[andOr, exprList]]]]];
    
    ZKBaseParser *where = [f zeroOrOne:[f seq:@[ws ,[f tokenSeq:@"WHERE"], cut, ws, exprList]]];
    
    /// FILTER SCOPE
    ZKBaseParser *filterScope = [f zeroOrOne:[f onMatch:[f seq:@[ws, [f tokenSeq:@"USING SCOPE"], ws, ident]] perform:^ZKParserResult*(ZKParserResult*r) {
        Token *t = [Token txt:r.userContext[KeySoqlText] loc:[[r child:3] loc]];
        t.type = TTUsingScope;
        [r.userContext[KeyTokens] addToken:t];
        return r;
    }]];

    /// DATA CATEGORY
    ZKBaseParser *withDataCat = [f withDataCategory];
    
    /// GROUP BY
    ZKBaseParser *groupBy = [f seq:@[ws, [f tokenSeq:@"GROUP BY"], cut, ws, [f oneOrMore:fieldOrFunc separator:commaSep]]];
    ZKBaseParser *groupByFieldList = [f seq:@[[f eq:@"("], maybeWs, [f oneOrMore:fieldOrFunc separator:commaSep], maybeWs, [f eq:@")"]]];
    ZKBaseParser *groupByRollup = [f seq:@[ws, [f tokenSeq:@"GROUP BY ROLLUP"], cut, maybeWs, groupByFieldList]];
    ZKBaseParser *groupByCube = [f seq:@[ws, [f tokenSeq:@"GROUP BY CUBE"], cut, maybeWs, groupByFieldList]];
    
    ZKBaseParser *having = [f zeroOrOne:[f seq:@[ws ,[f tokenSeq:@"HAVING"], cut, ws, exprList]]];
    ZKBaseParser *groupByClause = [f zeroOrOne:[f seq:@[[f firstOf:@[groupByRollup, groupByCube, groupBy]], having]]];
    
    /// ORDER BY
    ZKBaseParser *ascDesc = [f seq:@[ws, [f oneOfTokens:@[@"ASC",@"DESC"] type:TTKeyword completions:nil addToContext:TRUE]]];
    ZKBaseParser *nulls = [f seq:@[ws, [f tokenSeq:@"NULLS"], ws, [f oneOfTokens:@[@"FIRST",@"LAST"] type:TTKeyword completions:nil addToContext:TRUE]]];
                                
    ZKBaseParser *orderByField = [f seq:@[fieldOrFunc, [f zeroOrOne:ascDesc], [f zeroOrOne:nulls]]];
    ZKBaseParser *orderByFields = [f zeroOrOne:[f seq:@[maybeWs, [f tokenSeq:@"ORDER BY"], cut, ws, [f oneOrMore:orderByField separator:commaSep]]]];
                                   
    ZKBaseParser *limit = [f zeroOrOne:[f onMatch:[f seq:@[maybeWs, [f tokenSeq:@"LIMIT"], cut, maybeWs, [f integerNumber]]] perform:^ZKParserResult*(ZKParserResult*r) {
        Token *t = [Token txt:r.userContext[KeySoqlText] loc:[[r child:4] loc]];
        t.type = TTLiteralNumber;
        t.value = r.val;
        [r.userContext[KeyTokens] addToken:t];
        return r;
    }]];
    ZKBaseParser *offset= [f zeroOrOne:[f onMatch:[f seq:@[maybeWs, [f tokenSeq:@"OFFSET"], cut, maybeWs, [f integerNumber]]] perform:^ZKParserResult*(ZKParserResult*r) {
        Token *t = [Token txt:r.userContext[KeySoqlText] loc:[[r child:4] loc]];
        t.type = TTLiteralNumber;
        t.value = r.val;
        [r.userContext[KeyTokens] addToken:t];
        return r;
    }]];

    ZKBaseParser *forView = [f zeroOrOne:[f seq:@[maybeWs, [f tokenSeq:@"FOR"], cut, ws,
                                                  [f oneOfTokens:@[@"VIEW",@"REFERENCE"] type:TTKeyword completions:nil addToContext:TRUE]]]];
    ZKBaseParser *updateTracking = [f zeroOrOne:[f seq:@[maybeWs, [f tokenSeq:@"UPDATE"], cut, ws,
                                                         [f oneOfTokens:@[@"TRACKING", @"VIEWSTAT"] type:TTKeyword completions:nil addToContext:TRUE]]]];

    /// SELECT
    selectStmt.parser = [f seq:@[maybeWs, [f tokenSeq:@"SELECT"], ws, selectExprs, ws, [f tokenSeq:@"FROM"], ws, objectRefs,
                                  filterScope, where, withDataCat, groupByClause, orderByFields, limit, offset, forView, updateTracking, maybeWs]];
    selectStmt.debugName = @"SelectStmt";

    ///
    /// SOSL
    ///
    
    ZKBaseParser *inExpr = [f zeroOrOne:[f onMatch:[f seq:@[f.maybeWhitespace, [f tokenSeq:@"IN"], f.cut, f.whitespace,
                                                 [f oneOfTokens:@[@"ALL",@"NAME",@"EMAIL",@"PHONE",@"SIDEBAR"] type:TTKeyword completions:nil addToContext:TRUE],
                                                 f.whitespace, [f tokenSeq:@"FIELDS"]]] perform:pick(3)]];

    ZKBaseParser *object_id = [f onMatch:ident perform:^ZKParserResult *(ZKParserResult *r) {
        Token *t = [Token txt:r.userContext[KeySoqlText] loc:[r loc]];
        t.type = TTSObject;
        t.value = r.val;
        [r.userContext[KeyTokens] addToken:t];
        r.val = t;
        return r;
    }];
    ZKBaseParser *field_id = [f onMatch:ident perform:^ZKParserResult *(ZKParserResult *r) {
        Token *t = [Token txt:r.userContext[KeySoqlText] loc:[r loc]];
        t.type = TTFieldPath;
        t.value = @[r.val];
        [r.userContext[KeyTokens] addToken:t];
        return r;
    }];
    
    /// USING LISTVIEW
    ZKBaseParser *listview_name = [f onMatch:ident perform:^ZKParserResult *(ZKParserResult *r) {
        Token *t = [Token txt:r.userContext[KeySoqlText] loc:[r loc]];
        t.type = TTListViewName;
        t.value = r.val;
        [r.userContext[KeyTokens] addToken:t];
        return r;
    }];
    ZKBaseParser *listview = [f zeroOrOne:[f seq:@[maybeWs, [f tokenSeq:@"USING LISTVIEW"], maybeWs, cut, [f tokenSeq:@"="], maybeWs, listview_name]]];
 
    ZKBaseParser *limitoffset = [f seq:@[maybeWs, [f zeroOrOne:limit], [f zeroOrOne:offset]]];
    ZKBaseParser *fields = [f seq:@[f.maybeWhitespace, [f eq:@"("], f.maybeWhitespace, [f oneOrMore:field_id separator:commaSep], where, listview, orderByFields, limitoffset, [f eq:@")"]]];
    ZKBaseParser *object = [f onMatch:[f seq:@[maybeWs, object_id, [f zeroOrOne:fields], limitoffset]] perform:^ZKParserResult *(ZKParserResult *r) {
        ZKParserResult *o = [r child:1];
        if (![r childIsNull:2]) {
            Token *to = o.val;
            Tokens *tokens = r.userContext[KeyTokens];
            NSInteger objend = NSMaxRange(o.loc);
            to.value = [tokens cutPositionRange:NSMakeRange(objend, NSMaxRange(r.loc)-objend)];
        }
        return r;
    }];
    ZKBaseParser *returning = [f seq:@[f.maybeWhitespace, [f tokenSeq:@"RETURNING"], [f oneOrMore:object separator:commaSep]]];
    ZKBaseParser *queryTerm = [self soslSearchQuery:f];
    ZKBaseParser *sosl = [f seq:@[f.maybeWhitespace, [f tokenSeq:@"FIND"],
                                  f.maybeWhitespace, queryTerm,
                                  [f zeroOrOne:inExpr],
                                  [f zeroOrOne:returning],
                                  [f zeroOrOne:[f withDataCategory]]
                                ]];
    sosl.debugName = @"SoslStmt";


    return [f firstOf:@[selectStmt, sosl]];
}


-(ZKBaseParser*)soslSearchQuery:(ZKParserFactory*)f {
    ZKBaseParser *oneTerm = [f fromBlock:^ZKParserResult *(ZKParsingState *input) {
        NSInteger start = input.pos;
        BOOL inQuote = NO;
        NSCharacterSet *wsCharset = [NSCharacterSet whitespaceAndNewlineCharacterSet];
        while (true) {
            if (!input.hasMoreInput) {
                [input error:[NSString stringWithFormat:@"reached end of input while parsing the search term at %lu", input.pos]].pos--;
                return nil;
            }
            unichar c = input.currentChar;
            if (c == '\\') {
                input.pos++;
                if (!input.hasMoreInput) {
                    [input error:[NSString stringWithFormat:@"invalid escape sequence at %lu", input.pos]].pos--;
                }
                input.pos++;
                continue;
            }
            if (c == '"') {
                inQuote = !inQuote;
                input.pos++;
                continue;
            }
            if (!inQuote) {
                if (c == '}' || c == ')' || [wsCharset characterIsMember:c]) {
                    break;
                }
            }
            input.pos++;
        }
        NSRange overalRng = NSMakeRange(start,input.pos-start);
        if (overalRng.length > 0) {
            Token *t = [Token txt:input.input loc:overalRng];
            t.type = TTLiteralString; // TODO
            [input.userContext[KeyTokens] addToken:t];
            return [ZKParserResult result:t ctx:input.userContext loc:overalRng];
        }
        [input expectedClass:@"Search term"];
        return nil;
    }];
    oneTerm.debugName = @"A Term";
    ZKParserRef *exprList = [f parserRef];
    ZKBaseParser *paransExpr = [f seq:@[[f eq:@"("], f.maybeWhitespace, exprList, f.maybeWhitespace, [f eq:@")"]]];
    ZKBaseParser *andOrOp = [f firstOf:@[[f tokenSeq:@"OR"], [f seq:@[[f tokenSeq:@"AND"], f.maybeWhitespace, [f zeroOrOne:[f tokenSeq:@"NOT"]]]]]];
    andOrOp.debugName = @"AndOrOp";
    ZKBaseParser *andOr = [f firstOf:@[[f seq:@[andOrOp, f.maybeWhitespace, exprList]], oneTerm]];

    exprList.parser = [f seq:@[[f firstOf:@[paransExpr, oneTerm]], f.maybeWhitespace, [f zeroOrOne:andOr]]];
    exprList.debugName = @"exprList";

    ZKBaseParser *q = [f seq:@[[f eq:@"{"], f.maybeWhitespace, exprList, f.maybeWhitespace, [f eq:@"}"]]];
    return q;
}

@end

@implementation ZKParserFactory(SoqlX)

// constructs a seq parser for each whitespace separated token, e.g. given input "NULLS LAST" will generate
// seq:"NULLS", ws, "LAST".
-(ZKBaseParser*)tokenSeq:(NSString *)t type:(TokenType)type {
    NSArray<NSString*>* tokens = [t componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSMutableArray *seq = [NSMutableArray arrayWithCapacity:tokens.count *2];
    NSEnumerator *e = [tokens objectEnumerator];
    [seq addObject:[self eq:[e nextObject]]];
    do {
        NSString *next = [e nextObject];
        if (next == nil) break;
        [seq addObject:self.whitespace];
        [seq addObject:[self eq:next]];
    } while(true);
    ZKBaseParser *p = seq.count == 1 ? seq[0] : [self seq:seq];
    return [self onMatch:p perform:^ZKParserResult*(ZKParserResult*r) {
        Token *tkn = [Token txt:r.userContext[KeySoqlText] loc:r.loc];
        tkn.type = type;
        tkn.value = t;
        r.val = tkn;
        [r.userContext[KeyTokens] addToken:tkn];
        return r;
    }];
};

-(ZKBaseParser*)tokenSeq:(NSString *)t {
    return [self tokenSeq:t type:TTKeyword];
};

// Completions can be nil, in which case they'll be autogenerated from the supplied token type & tokens.
-(ZKBaseParser*)oneOfTokens:(NSArray<NSString*>*)tokens type:(TokenType)type completions:(NSArray<Completion*>*)completions addToContext:(BOOL)addToContext {
    if (completions == nil) {
        completions = [Completion completions:tokens type:type];
    }
    ZKBaseParser *p = [self oneOfTokensList:tokens];
    p = [self onError:p perform:^(ZKParsingState *input) {
        NSString *errClass = [NSString stringWithFormat:@"one of %@", [tokens componentsJoinedByString:@","]];
        [input expectedClass:errClass].userInfo = [NSMutableDictionary dictionaryWithObject:completions forKey:KeyCompletions];
    }];
    p = [self onMatch:p perform:^ZKParserResult *(ZKParserResult *r) {
        Token *t = [Token txt:r.userContext[KeySoqlText] loc:r.loc];
        t.type = type;
        [t.completions addObjectsFromArray:completions];
        r.val = t;
        if (addToContext) {
            [r.userContext[KeyTokens] addToken:t];
        }
        return r;
    }];
    return p;
}

-(ZKBaseParser*)ident {
    ZKBaseParser* identHead = [self characters:[NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"]
                               name:@"identifier"
                                min:1];
    ZKBaseParser* identTail = [self characters:[NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_"]
                               name:@"identifier"
                                min:0];
    ZKBaseParser *ident = [self onMatch:[self seq:@[identHead, identTail]] perform:^ZKParserResult *(ZKParserResult *r) {
        if (![r childIsNull:1]) {
            r.val = [NSString stringWithFormat:@"%@%@", [[r child:0] val], [[r child:1] val]];
        } else {
            r.val = [[r child:0] val];
        }
        return r;
    }];
    ident.debugName = @"ident";
    return ident;
}

-(ZKBaseParser*)comma {
    return [self seq:@[self.maybeWhitespace, [self eq:@","], self.maybeWhitespace]];
}

-(ZKBaseParser*)literalStringValue {
    ZKBaseParser *p = [self fromBlock:^ZKParserResult *(ZKParsingState *input) {
        NSInteger start = input.pos;
        if ((!input.hasMoreInput) || input.currentChar != '\'') {
            [input expected:@"'"];
            return nil;
        }
        input.pos++;
        [input markCut];
        while (true) {
            if (!input.hasMoreInput) {
                [input error:[NSString stringWithFormat:@"reached end of input while parsing a string literal, missing closing ' at %lu", input.pos]].pos--;
                return nil;
            }
            unichar c = input.currentChar;
            if (c == '\\') {
                input.pos++;
                if (!input.hasMoreInput) {
                    [input error:[NSString stringWithFormat:@"invalid escape sequence at %lu", input.pos]].pos--;
                }
                input.pos++;
                continue;
            }
            input.pos++;
            if (c == '\'') {
                break;
            }
        }
        // range includes the ' tokens, the value does not.
        NSRange overalRng = NSMakeRange(start,input.pos-start);
        Token *t = [Token txt:input.input loc:overalRng];
        t.type = TTLiteralString;
        return [ZKParserResult result:t ctx:input.userContext loc:overalRng];
    }];
    p.debugName = @"Literal String";
    return p;
}

-(ZKBaseParser*)literalValue {
    ZKBaseParser *literalStringValue = [self literalStringValue];
    ZKBaseParser *literalNullValue = [self onMatch:[self eq:@"null"] perform:^ZKParserResult *(ZKParserResult *r) {
        Token *t = [Token txt:r.userContext[KeySoqlText] loc:r.loc];
        t.type = TTLiteralNull;
        t.value = [NSNull null];
        r.val = t;
        return r;
    }];
    ZKBaseParser *literalTrueValue = [self onMatch:[self eq:@"true"] perform:^ZKParserResult *(ZKParserResult *r) {
        Token *t = [Token txt:r.userContext[KeySoqlText] loc:r.loc];
        t.type = TTLiteralBoolean;
        t.value = @TRUE;
        r.val = t;
        return r;
    }];
    ZKBaseParser *literalFalseValue = [self onMatch:[self eq:@"false"] perform:^ZKParserResult *(ZKParserResult *r) {
        Token *t = [Token txt:r.userContext[KeySoqlText] loc:r.loc];
        t.type = TTLiteralBoolean;
        t.value = @FALSE;
        r.val = t;
        return r;
    }];
    ZKBaseParser *literalNumberValue = [self onMatch:[self decimalNumber] perform:^ZKParserResult *(ZKParserResult *r) {
        Token *t = [Token txt:r.userContext[KeySoqlText] loc:r.loc];
        t.type = TTLiteralNumber;
        t.value = r.val;
        r.val = t;
        return r;
    }];
    NSError *err = nil;
    NSRegularExpression *dateTime = [NSRegularExpression regularExpressionWithPattern:@"\\d\\d\\d\\d-\\d\\d-\\d\\d(?:T\\d\\d:\\d\\d:\\d\\d(?:Z|[+-]\\d\\d:\\d\\d))?"
                                                                              options:NSRegularExpressionCaseInsensitive
                                                                                error:&err];
    NSAssert(err == nil, @"failed to compile regex %@", err);
    NSISO8601DateFormatter *dfDateTime = [NSISO8601DateFormatter new];
    NSISO8601DateFormatter *dfDate = [NSISO8601DateFormatter new];
    dfDate.formatOptions = NSISO8601DateFormatWithFullDate | NSISO8601DateFormatWithDashSeparatorInDate;
    ZKBaseParser *literalDateTimeValue = [self onMatch:[self regex:dateTime name:@"date/time literal"] perform:^ZKParserResult *(ZKParserResult *r) {
        Token *t = [Token txt:r.userContext[KeySoqlText] loc:r.loc];
        NSString *dt = r.val;
        if (dt.length == 10) {
            t.value = [dfDate dateFromString:dt];
            t.type = TTLiteralDate;
        } else {
            t.value = [dfDateTime dateFromString:dt];
            t.type = TTLiteralDateTime;
        }
        r.val = t;
        return r;
    }];
    NSRegularExpression *currency = [NSRegularExpression regularExpressionWithPattern:@"[a-z]{3}\\d+(?:\\.\\d+)?"
                                                                           options:NSRegularExpressionCaseInsensitive
                                                                             error:&err];
    NSAssert(err == nil, @"failed to compile regex %@", err);
    ZKBaseParser *literalCurrency = [self onMatch:[self regex:currency name:@"currency"] perform:^ZKParserResult *(ZKParserResult *r) {
        Token *t = [Token txt:r.userContext[KeySoqlText] loc:r.loc];
        t.type = TTLiteralCurrency;
        t.value = r.val;
        r.val = t;
        return r;
    }];

    NSRegularExpression *token = [NSRegularExpression regularExpressionWithPattern:@"[a-z][a-z0-9:_\\-\\.]*"
                                                                           options:NSRegularExpressionCaseInsensitive
                                                                             error:&err];
    NSAssert(err == nil, @"failed to compile regex %@", err);
    ZKBaseParser *literalToken = [self onMatch:[self regex:token name:@"named literal"] perform:^ZKParserResult *(ZKParserResult *r) {
        Token *t = [Token txt:r.userContext[KeySoqlText] loc:r.loc];
        t.type = TTLiteralNamedDateTime;
        t.value = r.val;
        r.val = t;
        return r;
    }];
    ZKBaseParser *literalValue = [self onMatch:[self firstOf:@[literalStringValue, literalNullValue, literalTrueValue, literalFalseValue,
                                                               literalDateTimeValue, literalNumberValue, literalCurrency, literalToken]]
                                       perform:^ZKParserResult *(ZKParserResult *r) {
            [r.userContext[KeyTokens] addToken:r.val];
            return r;
    }];
    literalValue.debugName = @"LiteralVal";
    return literalValue;
}

-(ZKBaseParser*)withDataCategory {
    /// DATA CATEGORY
    ZKBaseParser* cut = [self cut];
    ZKBaseParser* ws = [self whitespace];
    ZKBaseParser* maybeWs = [self maybeWhitespace];
    ZKBaseParser* ident = [self ident];
    ZKBaseParser *aCategory = [self onMatch:ident perform:^ZKParserResult*(ZKParserResult*r) {
        Token *t = [Token txt:r.userContext[KeySoqlText] loc:r.loc];
        t.type = TTDataCategoryValue;
        [r.userContext[KeyTokens] addToken:t];
        return r;
    }];
    ZKBaseParser* commaSep = [self comma];

    ZKBaseParser *catList = [self seq:@[[self eq:@"("], maybeWs, [self oneOrMore:aCategory separator:commaSep], maybeWs, [self eq:@")"]]];
    ZKBaseParser *catFilterVal = [self firstOf:@[catList, aCategory]];
    
    NSArray<NSString*>* catOperators = @[@"AT", @"ABOVE", @"BELOW", @"ABOVE_OR_BELOW"];
    ZKBaseParser *catFilter = [self onMatch:[self seq:@[ident, ws,
                                                  [self oneOfTokens:catOperators type:TTKeyword completions:nil addToContext:TRUE],
                                                  cut, maybeWs, catFilterVal]]
                                 perform:^ZKParserResult*(ZKParserResult*r) {
        Token *t = [Token txt:r.userContext[KeySoqlText] loc:[[r child:0] loc]];
        t.type = TTDataCategory;
        [r.userContext[KeyTokens] addToken:t];
        return r;
    }];
    ZKBaseParser *withDataCat = [self zeroOrOne:[self seq:@[ws, [self tokenSeq:@"WITH DATA CATEGORY"], cut, ws,
                                                      [self oneOrMore:catFilter separator:[self seq:@[ws,[self tokenSeq:@"AND" type:TTOperator],ws]]]]]];
    return  withDataCat;
}


@end
