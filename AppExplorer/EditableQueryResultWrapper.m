// Copyright (c) 2007-2015,2018,2020 Simon Fell
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

#import "EditableQueryResultWrapper.h"
#import "QueryResultCell.h"
#import <ZKSforce/ZKQueryResult+NSTableView.h>
#import <ZKSforce/ZKSObject.h>
#import "SObject.h"

NSString *DELETE_COLUMN_IDENTIFIER = @"row__delete";
NSString *ERROR_COLUMN_IDENTIFIER = @"row__error";

@interface EQRWMutating : NSObject {
    NSMutableArray *rows;
    NSMutableArray *checkMarks;
    NSMutableArray *errors;
}
-(instancetype)initWithRows:(NSArray *)rows errors:(NSDictionary *)errors checkMarks:(NSSet *)checks NS_DESIGNATED_INITIALIZER;
-(instancetype)init NS_UNAVAILABLE;

-(void)removeRowAtIndex:(NSInteger)index;
@property (readonly, copy) NSArray *rows;
@property (readonly, copy) NSArray *checkMarks;
@property (readonly, copy) NSArray *errors;
@end

@implementation EQRWMutating 

-(instancetype)initWithRows:(NSArray *)r errors:(NSDictionary *)err checkMarks:(NSSet *)checks {
    self = [super init];
    rows = [NSMutableArray arrayWithArray:r];
    checkMarks = [NSMutableArray arrayWithCapacity:rows.count];
    errors = [NSMutableArray arrayWithCapacity:rows.count];
    for (int i =0; i < rows.count; i++) {
        [checkMarks addObject:@FALSE];
        [errors addObject:[NSNull null]];
    }
    for (NSNumber *n in checks) 
        checkMarks[n.intValue] = @TRUE;
    
    for (NSNumber *n in err.allKeys)
        errors[n.intValue] = err[n];
    return self;
}

-(void)removeRowAtIndex:(NSInteger)index {
    [rows removeObjectAtIndex:index];
    [checkMarks removeObjectAtIndex:index];
    [errors removeObjectAtIndex:index];
}

-(NSArray *)rows {
    return rows;
}

-(NSArray *)checkMarks {
    return checkMarks;
}

-(NSArray *)errors {
    return errors;
}

@end

@implementation EditableQueryResultWrapper

- (instancetype)initWithQueryResult:(ZKQueryResult *)qr {
    self = [super init];
    result = qr;
    editable = NO;
    imageCell = [[QueryResultCell alloc] initTextCell:@""];
    checkedRows = [[NSMutableSet alloc] init];
    rowErrors = [[NSMutableDictionary alloc] init];
    return self;
}


- (id)createMutatingRowsContext {
    EQRWMutating *c = [[EQRWMutating alloc] initWithRows:[result records] errors:rowErrors checkMarks:checkedRows];
    return c;
}

- (void)remmoveRowAtIndex:(NSInteger)index context:(id)mutatingContext {
    [(EQRWMutating *)mutatingContext removeRowAtIndex:index];
}

- (void)updateRowsFromContext:(id)context {
    EQRWMutating *ctx = (EQRWMutating *)context;
    NSArray *rows = [ctx rows];
    [self clearErrors];
    int r = 0;
    for (id err in [ctx errors]) {
        if (err != [NSNull null])
            [self addError:(NSString *)err forRowIndex:@(r)];
        ++r;
    }
    r = 0;
    [self willChangeValueForKey:@"hasCheckedRows"];
    [checkedRows removeAllObjects];
    for (NSNumber *c in [ctx checkMarks]) {
        if (c.boolValue) 
            [checkedRows addObject:@(r)];
        ++r;
    }
    [self didChangeValueForKey:@"hasCheckedRows"];
    
    NSInteger rowCountDiff = [result records].count - rows.count;
    ZKQueryResult *nr = [[ZKQueryResult alloc] initWithRecords:rows size:[result size] - rowCountDiff done:[result done] queryLocator:[result queryLocator]];
    [self setQueryResult:nr];
}

-(NSArray *)allSystemColumnIdentifiers {
    return @[DELETE_COLUMN_IDENTIFIER, ERROR_COLUMN_IDENTIFIER];
}

- (void)setQueryResult:(ZKQueryResult *)newResults {
    if (result == newResults) return;
    result = newResults;
}

- (ZKQueryResult *)queryResult {
    return result;
}

- (BOOL)editable {
    return editable;
}

- (void)setEditable:(BOOL)newAllowEdit {
    editable = newAllowEdit;
}

- (NSObject<EditableQueryResultWrapperDelegate> *)delegate {
    return delegate;
}

- (void)setDelegate:(NSObject<EditableQueryResultWrapperDelegate> *)aValue {
    delegate = aValue;
}

- (BOOL)hasCheckedRows {
    return checkedRows.count > 0;
}

- (BOOL)hasErrors {
    return rowErrors.count > 0;
}

- (void)clearErrors {
    [rowErrors removeAllObjects];
}

- (void)addError:(NSString *)errMsg forRowIndex:(NSNumber *)index {
    rowErrors[index] = errMsg;
}

- (NSInteger)size {
    return [result size];
}

- (BOOL)done {
    return [result done];
}

- (NSString *)queryLocator {
    return [result queryLocator];
}

- (NSArray *)records {
    return [result records];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)v {
    return [result numberOfRowsInTableView:v];
}

- (id)tableView:(NSTableView *)view objectValueForTableColumn:(NSTableColumn *)tc row:(NSInteger)rowIdx {
    if ([tc.identifier isEqualToString:DELETE_COLUMN_IDENTIFIER]) 
        return @([checkedRows containsObject:@(rowIdx)]);
    if ([tc.identifier isEqualToString:ERROR_COLUMN_IDENTIFIER])
        return rowErrors[@(rowIdx)];
    return [self columnValue:tc.identifier atRow:rowIdx];
}

- (BOOL)allowEdit:(NSTableColumn *)aColumn {
    if (!editable) return NO;
    if (delegate.isEditing) return NO;
    if ([aColumn.identifier isEqualToString:ERROR_COLUMN_IDENTIFIER]) return NO;
    return [aColumn.identifier rangeOfString:@"."].location == NSNotFound;
}

- (BOOL)control:(NSControl *)control textShouldBeginEditing:(NSText *)fieldEditor {
    NSTableView *t = (NSTableView *)control;
    NSTableColumn *c =t.tableColumns[t.editedColumn];
    return [self allowEdit:c];
}

- (BOOL)control:(NSControl *)control textShouldEndEditing:(NSText *)fieldEditor {
    return YES;
}

- (void)setChecksOnAllRows:(BOOL)checked {
    [self willChangeValueForKey:@"hasCheckedRows"];
    if (checked) {
        NSInteger rows = [result records].count;
        for (NSInteger i = 0; i < rows; i++)
            [checkedRows addObject:@(i)];
    } else {
        [checkedRows removeAllObjects];
    }
    [self didChangeValueForKey:@"hasCheckedRows"];
}

- (void)setChecked:(BOOL)checked onRowWithIndex:(NSNumber *)index {
    BOOL dcv = checkedRows.count < 2;
    if (dcv) [self willChangeValueForKey:@"hasCheckedRows"];
    if (checked)
        [checkedRows addObject:index];
    else
        [checkedRows removeObject:index];
    if (dcv) [self didChangeValueForKey:@"hasCheckedRows"];
}

- (NSUInteger)numCheckedRows {
    return checkedRows.count;
}

- (NSSet *)indexesOfCheckedRows {
    return checkedRows;
}

- (void)tableView:(NSTableView *)tableView didClickTableColumn:(NSTableColumn *)tableColumn {
    if ([tableColumn.identifier isEqualToString:DELETE_COLUMN_IDENTIFIER]) {
        [self setChecksOnAllRows:![self hasCheckedRows]];
        [tableView reloadData];
    }
}

- (void)tableView:(NSTableView *)aTableView
    setObjectValue:(id)anObject
    forTableColumn:(NSTableColumn *)aTableColumn
    row:(NSInteger)rowIndex
{
    BOOL allow = [self allowEdit:aTableColumn];
    if (!allow) return;
    if ([aTableColumn.identifier isEqualToString:@"Id"]) 
        return;    // Id column is not really editable

    BOOL isDelete = [aTableColumn.identifier isEqualToString:DELETE_COLUMN_IDENTIFIER];
    if (isDelete) {
        NSNumber *r = [NSNumber numberWithInteger:rowIndex];
        BOOL currentState = [checkedRows containsObject:r];
        [self setChecked:!currentState onRowWithIndex:r]; 
    } else {
        if (delegate != nil && [delegate respondsToSelector:@selector(dataChangedOnObject:field:value:)]) {
            [delegate dataChangedOnObject:[result records][rowIndex] field:aTableColumn.identifier value:anObject];
        }
    }
}

- (NSCell *)tableView:(NSTableView *)tableView dataCellForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    if (tableColumn == nil) return nil;
    id v = [self columnValue:tableColumn.identifier atRow:row];
    if ([v isKindOfClass:[ZKQueryResult class]])
        return imageCell;
    return [tableColumn dataCellForRow:row];
}

- (void)tableView:(NSTableView *)tableView sortDescriptorsDidChange:(NSArray<NSSortDescriptor *> *)oldDescriptors {
    NSLog(@"sortDescriptorsDidChange: %@", tableView.sortDescriptors);
//    NSMutableArray *wrapped = [NSMutableArray arrayWithCapacity:result.records.count];
    describeProvider p = self.describer;
    //for (ZKSObject *row in result.records) {
      //  [wrapped addObject:[SObject wrap:row provider:p]];
    //}
    for (ZKSObject *row in result.records) {
        row.provider = p;
    }
    NSArray *sorted = [result.records sortedArrayUsingDescriptors:tableView.sortDescriptors];
    ZKQueryResult *r = [[ZKQueryResult alloc] initWithRecords:sorted size:result.size done:result.done queryLocator:result.queryLocator];
    self.queryResult = r;
    [tableView reloadData];
}

-(id)columnValue:(NSString *)col atRow:(NSUInteger)row {
    NSArray *fieldPath = [col componentsSeparatedByString:@"."];
    NSObject *val = result.records[row];
    for (NSString *step in fieldPath) {
        if ([val isKindOfClass:[ZKSObject class]] || [val isKindOfClass:[SObject class]]) {
            val = [(ZKSObject *)val fieldValue:step];
        } else {
            val = [val valueForKey:step];
        }
    }
    return val;
}

@end
