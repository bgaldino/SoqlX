//
//  SoqlTokenizer.m
//  AppExplorer
//
//  Created by Simon Fell on 4/17/21.
//

#include <mach/mach_time.h>

#import <objc/runtime.h>
#import "SoqlTokenizer.h"
#import "DataSources.h"
#import "CaseInsensitiveStringKey.h"
#import "ColorizerStyle.h"
#import "SoqlToken.h"
#import "SoqlParser.h"

@interface SoqlScanner : NSObject {
    NSString       *txt;
    NSUInteger      pos;
    NSCharacterSet *defSeparator;
    NSCharacterSet *ws;
}
+(instancetype)withString:(NSString *)s;
-(Token *)until:(NSCharacterSet*)sep;
-(Token *)consume:(NSString *)txt caseSensitive:(BOOL)cs;
-(Token *)consumeChars:(NSCharacterSet *)cs;
-(Token *)nextToken;
-(Token *)peekToken;
-(unichar)peek;
// returns true if at EOF after skip.
-(BOOL)skipWs;
// returns true if at EOF after or during skip
-(BOOL)skip:(NSUInteger)n;

-(NSUInteger)posn;
-(BOOL)eof;

-(NSString *)txtOf:(NSRange)r;
@end

@implementation SoqlScanner

+(instancetype)withString:(NSString *)s {
    SoqlScanner *c = [SoqlScanner new];
    c->txt = [s copy];
    c->pos = 0;
    c->defSeparator = [NSCharacterSet characterSetWithCharactersInString:@" \r\n\t(),"];
    c->ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    return c;
}

-(NSString *)txtOf:(NSRange)r {
    return [txt substringWithRange:r];
}

-(Token*)tokenOf:(NSRange)r {
    return [Token txt:txt loc:r];
}

-(BOOL)eof {
    return pos >= txt.length;
}

-(NSUInteger)posn {
    return pos;
}

-(BOOL)skip:(NSUInteger)n {
    pos += n;
    return [self eof];
}

// Skips any whitespace chars. returns true if at EOF.
-(BOOL)skipWs {
    for (; pos < txt.length; pos++) {
        unichar p = [txt characterAtIndex:pos];
        if (![ws characterIsMember:p]) {
            break;
        }
    }
    return [self eof];
}

-(Token *)peekToken {
    NSUInteger start = pos;
    Token *t = [self nextToken];
    pos = start;
    return t;
}

-(Token *)nextToken {
    return [self until:defSeparator];
}

-(Token *)consume:(NSString *)txt caseSensitive:(BOOL)cs {
    Token *t = [self peekToken];
    if (t.tokenTxt.length != txt.length) {
        return nil;
    }
    if ([t matches:txt caseSensitive:cs]) {
        pos += txt.length;
        return t;
    }
    return nil;
}

-(Token *)consumeChars:(NSCharacterSet *)cs {
    NSUInteger start = pos;
    for (; pos < txt.length; pos++) {
        unichar p = [txt characterAtIndex:pos];
        if (![cs characterIsMember:p]) {
            return [Token txt:txt loc:NSMakeRange(start,pos-start)];
        }
    }
    return [Token txt:txt loc:NSMakeRange(start, txt.length-start)];
}

-(Token *)until:(NSCharacterSet *)sep {
    NSUInteger start = pos;
    for (; pos < txt.length; pos++) {
        unichar p = [txt characterAtIndex:pos];
        if ([sep characterIsMember:p]) {
            return [Token txt:txt loc:NSMakeRange(start,pos-start)];
        }
    }
    return [Token txt:txt loc:NSMakeRange(start, txt.length-start)];
}

-(unichar)peek {
    NSAssert(![self eof], @"Can't peek at EOF");
    return [txt characterAtIndex:pos];
}

-(NSString*)description {
    return [self eof]? @"at EOF" : [txt substringFromIndex:pos];
}
@end

@interface SoqlTokenizer()
@property (strong,nonatomic) NSMutableArray<Token*> *tokens;
@property (strong,nonatomic) SoqlParser *soqlParser;
@end

@implementation SoqlTokenizer

static NSString *KeyCompletions = @"completions";

-(instancetype)init {
    self = [super init];
    self.soqlParser = [SoqlParser new];
    return self;
}

-(void)textDidChange:(NSNotification *)notification {
    [self color];
}

-(NSString *)scanTypeOf:(SoqlScanner*)sc {
    // TODO
    return nil;
}

-(void)scanExpr:(SoqlScanner*)sc {
    if ([sc skipWs]) return;
    [self scanFieldOrFunc:sc];
    if ([sc skipWs]) return;
    Token *op = sc.peekToken;
    NSSet<NSString*>*ops = [NSSet setWithArray:@[@">=",@"=",@">",@"<",@"<=",@"!=",@"LIKE",@"IN",@"NOT IN",@"INCLUDES",@"EXCLUDES"]];
    [op.completions addObjectsFromArray:[Completion completions:ops.allObjects type:TTOperator]];
    // TODO deal with NOT IN
    if (![ops containsObject:[op.tokenTxt uppercaseString]]) {
        op.type = TTError;
        op.value = [NSString stringWithFormat:@"Expecting one of %@", ops];
        [self.tokens addObject:op];
        [sc skip:op.loc.length];
        return;
    }
    op.type = TTOperator;
    [self.tokens addObject:op];
    [sc skip:op.loc.length];
    if ([sc skipWs]) return;
    NSArray<Completion*>* valueCompletions = [Completion
                                              completions:@[@"\'\'", @"NULL", @"TRUE", @"FALSE", @"2020-04-16", @"2020-04-16T12:00:00Z", @"42", @"42.42"]
                                              type:TTLiteral];
    unichar x = [sc peek];
    if (x == '(') {
        [sc skip:1];
        if ([sc skipWs]) return;
        if ([sc.peekToken matches:@"SELECT" caseSensitive:NO]) {
            NSUInteger start = sc.posn;
            NSMutableArray *tokens = self.tokens;
            self.tokens = [NSMutableArray arrayWithCapacity:10];
            [self scanSelect:sc];
            [sc skipWs];
            if ([sc eof] || [sc peek] != ')') {
                Token *err = [sc tokenOf:NSMakeRange(sc.posn, sc.eof ? 0 : 1)];
                err.type = TTError;
                err.value = @"Expecting closing )";
                [err.completions addObject:[Completion txt:@")" type:TTKeyword]];
                self.tokens = tokens;
                [self.tokens addObject:err];
                return;
            }
            [sc skip:1];
            Token *t = [sc tokenOf:NSMakeRange(start, sc.posn-start)];
            t.type = TTNestedSelect;
            t.value = self.tokens;
            self.tokens = tokens;
            [self.tokens addObject:t];
        } else {
            Token *literal = [sc until:[NSCharacterSet characterSetWithCharactersInString:@")"]];
            literal.type = TTLiteral;
            [self.tokens addObject:literal];
        }
    } else if (x == '\'') {
        [sc skip:1];
        Token *literal = [sc until:[NSCharacterSet characterSetWithCharactersInString:@"\'"]];
        literal.type = TTLiteral;
        [literal.completions addObjectsFromArray:valueCompletions];
        [self.tokens addObject:literal];
        [sc skip:1];
    } else if (x >= '0' && x <= '9') {
        Token *literal = [sc nextToken];
        literal.type = TTLiteral;
        [literal.completions addObjectsFromArray:valueCompletions];
        [self.tokens addObject:literal];
    } else {
        // should be date literals
        [self scanFieldOrFunc:sc];
    }
    if ([sc skipWs]) return;
    Token *next = [sc peekToken];
    if ([next matches:@"AND" caseSensitive:NO] || [next matches:@"OR" caseSensitive:NO]) {
        next.type = TTOperator;
        [next.completions addObject:[Completion txt:@"AND" type:TTKeyword]];
        [next.completions addObject:[Completion txt:@"OR" type:TTKeyword]];
        [self.tokens addObject:next];
        [sc skip:next.loc.length];
        [self scanExpr:sc];
    }
}

-(void)scanWhere:(SoqlScanner*)sc {
    Token *n = [sc peekToken];
    if ([n matches:@"WHERE" caseSensitive:NO]) {
        [sc skip:5];
        n.type = TTKeyword;
        [self.tokens addObject:n];
        [self scanExpr:sc];
    }
    // [self scan order by] etc
}

-(void)scanFrom:(SoqlScanner*)sc {
    if ([sc skipWs]) return;
    Token *t = [sc nextToken];
    t.type = TTSObject;
    [self.tokens addObject:t];
    if ([sc skipWs]) return;
    unichar n = [sc peek];
    while (n == ',') {
        [sc skip:1];
        [sc skipWs];
        Token *rel = [sc nextToken];
        rel.type = TTSObjectRelation;
        [self.tokens addObject:rel];
        if ([sc skipWs]) return;
        n = [sc peek];
    }
    [self scanWhere:sc];
}

-(void)scanFieldOrFunc:(SoqlScanner*)sc {
    Token *t = [sc peekToken];
    if ([t.tokenTxt containsString:@"."]) {
        t.type = TTFieldPath;
        [self.tokens addObject:t];
        [sc skip:t.loc.length];
    } else {
        // field or func
        [sc skip:t.loc.length];
        [sc skipWs];
        if (![sc eof] && [sc peek] == '(') {
            // func
            Token *name = t;
            Token *rest = [sc until:[NSCharacterSet characterSetWithCharactersInString:@")"]];
            // TODO, this should be separate tokens for the args
            NSRange r = NSUnionRange(name.loc,rest.loc);
            Token *fn = [sc tokenOf:r];
            fn.type = TTFunc;
            [sc skip:1];
            [self.tokens addObject:fn];
        } else {
            // field after all
            t.type = TTFieldPath;
            [self.tokens addObject:t];
        }
    }
}

-(void)scanSelectExprs:(SoqlScanner*)sc {
    if ([sc skipWs]) return;
    unichar n = [sc peek];
    if (n == '(') {
        NSUInteger start = sc.posn;
        NSMutableArray<Token*> *currentTokens = self.tokens;
        self.tokens = [NSMutableArray arrayWithCapacity:10];
        [sc skip:1];
        [self scanSelect:sc];
        [sc skipWs];
        if ([sc eof] || [sc peek] != ')') {
            Token *err = [sc nextToken];
            err.type = TTError;
            err.value = @"Expecting closing )";
            [err.completions addObject:[Completion txt:@")" type:TTKeyword]];
            self.tokens = currentTokens;
            [self.tokens addObject:err];
            return;
        }
        [sc skip:1];
        NSRange selectLoc = NSMakeRange(start,sc.posn-start);
        Token *select = [sc tokenOf:selectLoc];
        select.type = TTNestedSelect;
        select.value = self.tokens;
        self.tokens = currentTokens;
        [self.tokens addObject:select];
    } else {
        Token *t = [sc peekToken];
        if ([t matches:@"TYPEOF" caseSensitive:NO]) {
            [self scanTypeOf:sc];
        } else {
            [self scanFieldOrFunc:sc];
        }
    }
    [sc skipWs];
    if (![sc eof] && [sc peek] == ',') {
        [sc skip:1];
        [self scanSelectExprs:sc];
    } else {
        Token *from = [sc nextToken];
        if ([from matches:@"FROM" caseSensitive:NO]) {
            from.type = TTKeyword;
            [self.tokens addObject:from];
            [self scanFrom:sc];
        } else {
            from.type = TTError;
            [from.completions addObject:[Completion txt:@"FROM" type:TTKeyword]];
            from.value = @"expecting FROM";
            [self.tokens addObject:from];
        }
    }
}

-(void)scanSelect:(SoqlScanner*)sc {
    [sc skipWs];
    Token *t = [sc nextToken];
    if ([t matches:@"SELECT" caseSensitive:NO]) {
        t.type = TTKeyword;
        [self.tokens addObject:t];
        [self scanSelectExprs:sc];
    } else {
        t.type = TTError;
        t.value = @"Expected SELECT";
        [t.completions addObject:[Completion txt:@"SELECT" type:TTKeyword]];
        [self.tokens addObject:t];
    }
}

-(void)scanWithParser:(NSString*)input {
    NSError *err = nil;
    [self.tokens addObjectsFromArray:[self.soqlParser parse:input error:&err]];
    if (err != nil) {
        // TODO setting an error on the insertion point when its at the end of the string is problematic
        Token *t = [Token txt:input loc:NSMakeRange([err.userInfo[@"Position"] integerValue]-1, 0)];
        t.type = TTError;
        [self.tokens addObject:t];
    }
}

-(void)color {
    //NSLog(@"starting color");
    self.tokens = [NSMutableArray arrayWithCapacity:10];
    //SoqlScanner *sc = [SoqlScanner withString:self.view.textStorage.string];
    //[self scanSelect:sc];
    [self scanWithParser:self.view.textStorage.string];
    //NSLog(@"parsed tokens\n%@", self.tokens);
    [self resolveTokens:self.tokens];
    NSLog(@"resolved tokens\n%@", self.tokens);
    NSTextStorage *txt = self.view.textStorage;
    NSRange before =  [self.view selectedRange];
    [txt beginEditing];
    NSRange all = NSMakeRange(0,txt.length);
    [txt removeAttribute:NSToolTipAttributeName range:all];
    [txt addAttribute:NSForegroundColorAttributeName value:[NSColor whiteColor] range:all];
    [txt removeAttribute:NSToolTipAttributeName range:all];
    [self applyTokens:self.tokens];
    [txt endEditing];
    [self.view setSelectedRange:before];
}

-(void)resolveTokens:(NSMutableArray<Token*>*)tokens {
    // This is the 2nd pass that deals with resolving field/object/rel/alias/func tokens
    Token *tSObject;
    for (int i = 0; i < tokens.count; i++) {
        if (tokens[i].type == TTSObject) {
            tSObject = tokens[i];
            // TODO, deal with aliases, relationships etc.s
            break;
        }
    }
    [tSObject.completions addObjectsFromArray:[Completion completions:self.allQueryableSObjects type:TTSObject]];
    if (![self knownSObject:tSObject.tokenTxt]) {
        tSObject.type = TTError;
        tSObject.value = [NSString stringWithFormat:@"The SObject '%@' does not exist or is inaccessible", tSObject.tokenTxt];
        return;
    }
    NSMutableArray<Token*> *newTokens = [NSMutableArray arrayWithCapacity:4];
    NSMutableArray<Token*> *delTokens = [NSMutableArray arrayWithCapacity:4];
    ZKDescribeSObject *desc = [self describe:tSObject.tokenTxt];
    tSObject.value = desc;
    for (Token *sel in tokens) {
        if (sel.type == TTFieldPath) {
            [delTokens addObject:sel];
            NSArray<NSString*>* path = [sel.tokenTxt componentsSeparatedByString:@"."];
            NSInteger pos = sel.loc.location;
            ZKDescribeSObject *currentSObject = desc;
            for (NSString *step in path) {
                Token *tStep = [tSObject tokenOf:NSMakeRange(pos, step.length)];
                [tStep.completions addObjectsFromArray:[Completion completions:[currentSObject valueForKeyPath:@"fields.name"] type:TTField]];
                [tStep.completions addObjectsFromArray:[Completion
                                                        completions:[currentSObject.parentRelationshipsByName.allValues valueForKey:@"relationshipName"]
                                                        type:TTRelationship]];
                ZKDescribeField *f = [currentSObject fieldWithName:step];
                if (f == nil) {
                    ZKDescribeField *rel = [currentSObject parentRelationshipsByName][[CaseInsensitiveStringKey of:step]];
                    if (rel == nil) {
                        tStep.type = TTError;
                        tStep.value = [NSString stringWithFormat:@"The SObject %@ doesn't contain a field or relationship called %@", desc.name, step];
                        [newTokens addObject:tStep];
                        break;
                    } else {
                        tStep.type = TTRelationship;
                        tStep.value = rel;
                        if (rel.namePointing) {
                            currentSObject = [self describe:@"Name"];
                        } else {
                            currentSObject = [self describe:rel.referenceTo[0]];
                        }
                    }
                } else {
                    tStep.type = TTField;
                    tStep.value = f;
                }
                [newTokens addObject:tStep];
                pos += tStep.loc.length + 1;
           }
        } else if (sel.type == TTFunc) {
            
        } else if (sel.type == TTSObject) {
            break;
        }
    }
    for (Token *t in delTokens) {
        [tokens removeObject:t];
    }
    [tokens addObjectsFromArray:newTokens];
}

-(void)applyTokens:(NSArray<Token*>*)tokens {
    ColorizerStyle *style = [ColorizerStyle styles];
    NSTextStorage *txt = self.view.textStorage;
    for (Token *t in tokens) {
        if (t.completions.count > 0) {
            [txt addAttribute:KeyCompletions value:t.completions range:t.loc];
        }
        switch (t.type) {
            case TTFieldPath:
                [txt addAttributes:style.field range:t.loc];
                break;
            case TTKeyword:
                [txt replaceCharactersInRange:t.loc withString:[t.tokenTxt uppercaseString]];
                [txt addAttributes:style.keyWord range:t.loc];
                break;
            case TTOperator:
                [txt replaceCharactersInRange:t.loc withString:[t.tokenTxt uppercaseString]];
                [txt addAttributes:style.keyWord range:t.loc];
                break;
            case TTAlias:
            case TTTypeOf:
            case TTField:
            case TTRelationship:
            case TTSObject:
            case TTSObjectRelation:
            case TTAliasDecl:
                [txt addAttributes:style.field range:t.loc];
                break;
            case TTFunc:
                [txt addAttributes:style.field range:t.loc];
                break;
            case TTLiteral:
            case TTLiteralList:
                [txt addAttributes:style.literal range:t.loc];
                break;
            case TTNestedSelect:
                [self applyTokens:(NSArray<Token*>*)t.value];
                break;
            case TTError:
                [txt addAttributes:style.underlined range:t.loc];
                if (t.value != nil) {
                    [txt addAttribute:NSToolTipAttributeName value:t.value range:t.loc];
                }
                break;
            case TTUsingScope:
            case TTDataCategory:
            case TTDataCategoryValue:
                [txt addAttributes:style.field range:t.loc];
                break;
        }
    }
}


// Delegate only.  Allows delegate to modify the list of completions that will be presented for the partial word at the given range.  Returning nil or a zero-length array suppresses completion.  Optionally may specify the index of the initially selected completion; default is 0, and -1 indicates no selection.
-(NSArray<NSString *> *)textView:(NSTextView *)textView completions:(NSArray<NSString *> *)words forPartialWordRange:(NSRange)charRange indexOfSelectedItem:(nullable NSInteger *)index {
    return nil;
}

// Not part of NSTextView delegate, a similar version that ZKTextView calls. It doesn't use the regular delegate one
// because we need to return nil from that to supress the standard completions (via F5)
-(NSArray*)textView:(NSTextView *)textView completionsForPartialWordRange:(NSRange)charRange {
    NSLog(@"textView completions: for range %lu-%lu '%@' textLength:%ld", charRange.location, charRange.length,
          [textView.string substringWithRange:charRange], textView.textStorage.length);

    __block NSArray<NSString *>* completions = nil;
    [textView.textStorage enumerateAttribute:KeyCompletions inRange:charRange options:0 usingBlock:^(id  _Nullable value, NSRange range, BOOL * _Nonnull stop) {
        completions = value;
    }];
    if (completions != nil) {
        NSLog(@"found %lu completions", (unsigned long)completions.count);
        return [completions sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)];;
    }
    NSLog(@"no completions found at %lu-%lu", charRange.location, charRange.length);
    return nil;
}

-(ZKDescribeSObject*)describe:(NSString*)obj; {
    if ([self.describes hasDescribe:obj]) {
        return [self.describes cachedDescribe:obj];
    }
    if ([self.describes isTypeDescribable:obj]) {
        [self.describes prioritizeDescribe:obj];
    }
    return nil;
}

-(BOOL)knownSObject:(NSString*)obj {
    return [self.describes isTypeDescribable:obj];
}

-(NSArray<NSString*>*)allQueryableSObjects {
    return [[self.describes.SObjects filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"queryable=true"]] valueForKey:@"name"];
}


@end
