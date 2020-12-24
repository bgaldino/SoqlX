// Copyright (c) 2006,2014,2016,2018,2019 Simon Fell
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

#import "DataSources.h"
#import <ZKSforce/ZKSforce.h>
#import "HighlightTextFieldCell.h"
#import "ZKDescribeThemeItem+ZKFindResource.h"
#import "Prefs.h"
#import "ZKXsdAnyType.h"
#import "Describer.h"

@interface DescribeListDataSource ()
-(void)updateFilter;
-(void)prefsChanged:(NSNotification *)notif;
@property Describer *describer;
@end


@interface ZKDescribeField (ZKDataSourceHelpers)
-(BOOL)fieldMatchesFilter:(NSString *)filter;
-(NSString *)defaultValueAsString;
@end

@implementation ZKDescribeField (Filtering)

-(BOOL)fieldMatchesFilter:(NSString *)filter {
    if (filter == nil) return NO;
    return [self.name rangeOfString:filter options:NSCaseInsensitiveSearch].location != NSNotFound;
}

-(NSString *)defaultValueAsString {
    NSObject *dv = [[self defaultValue] value];
    return dv == nil ? @"" : dv.description;
}

@end

@implementation DescribeListDataSource

@synthesize delegate;

- (instancetype)init {
    self = [super init];
    fieldSortOrder = [NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES selector:@selector(localizedCaseInsensitiveCompare:)];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(prefsChanged:) name:NSUserDefaultsDidChangeNotification object:nil];
    self.describer = [[Describer alloc] init];
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

-(void)prefsChanged:(NSNotification *)notif {
    [outlineView reloadData];
}

- (void)setTypes:(ZKDescribeGlobalTheme *)t view:(NSOutlineView *)ov {
    outlineView = ov;
    types = t.global.sobjects;
    describes = [[NSMutableDictionary alloc] init];
    sortedDescribes = [[NSMutableDictionary alloc] init];
    icons = [[NSMutableDictionary alloc] init];
    
    NSMutableDictionary *byname = [NSMutableDictionary dictionary];
    for (ZKDescribeGlobalSObject *o in types)
        byname[o.name.lowercaseString] = o;
        
    descGlobalSobjects = byname;
    
    NSString *sid = sforce.sessionId;
    for (ZKDescribeThemeItem *r in t.theme.themeItems) {
        ZKDescribeIcon *i = [r iconWithHeight:16 theme:@"theme3"];
        [i fetchIconUsingSessionId:sid whenCompleteDo:^(NSImage *img) {
            NSString *tn = r.name.lowercaseString;
            self->icons[tn] = img;
            [self->outlineView reloadItem:byname[tn]];
        }];
    }
    [self.describer describe:t withClient:sforce andDelegate:self];
    [self updateFilter];
}

- (NSImage *)iconForType:(NSString *)type {
    return [icons valueForKey:type.lowercaseString];
}

- (void)setSforce:(ZKSforceClient *)sf {
    sforce = sf;
}

- (void)prioritizeDescribe:(NSString *)type {
    [self.describer prioritize:type];
}

-(void)setFilteredTypes:(NSArray *)t {
    NSArray *old = filteredTypes;
    filteredTypes = t;
    if (![old isEqualToArray:t])
        [outlineView reloadData];
}

-(BOOL)filterIncludesType:(NSString *)type {
    if ([type rangeOfString:filter options:NSCaseInsensitiveSearch].location != NSNotFound)
        return YES; // easy, type contains the filter clause
    if (![self hasDescribe:type]) 
        return NO;    // we haven't described it yet
    for (ZKDescribeField *f in [self cachedDescribe:type].fields) {
        if ([f fieldMatchesFilter:filter])
            return YES;
    }
    return NO;
}

-(void)updateFilter {
    if (filter.length == 0) {
        [self setFilteredTypes:types];
        return;
    }
    NSMutableArray *ft = [NSMutableArray array];
    for (ZKDescribeGlobalSObject *type in types) {
        if ([self filterIncludesType:type.name])
            [ft addObject:type];
    }
    [self setFilteredTypes:ft];
}

- (NSString *)filter {
    return filter;
}

- (void)setFilter:(NSString *)filterValue {
    filter = [filterValue copy];
    [self updateFilter];
}

- (NSArray *)SObjects {
    return types;
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)v {
    return filteredTypes.count;
}

- (id)tableView:(NSTableView *)view objectValueForTableColumn:(NSTableColumn *)tc row:(int)rowIdx {
    return [filteredTypes[rowIdx] name];
}

- (BOOL)isTypeDescribable:(NSString *)type {
    return nil != descGlobalSobjects[type.lowercaseString];
}

- (BOOL)hasDescribe:(NSString *)type {
    return nil != describes[type.lowercaseString];
}

-(ZKDescribeSObject *)cachedDescribe:(NSString *)type {
    return describes[type.lowercaseString];
}

- (void)describe:(NSString *)type
       failBlock:(ZKFailWithErrorBlock)failBlock
   completeBlock:(ZKCompleteDescribeSObjectBlock)completeBlock {

    NSString *t = type.lowercaseString;
    ZKDescribeSObject * d = describes[t];
    if (d != nil || ![self isTypeDescribable:t]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completeBlock(d);
        });
        return;
    }
    [sforce describeSObject:type
                  failBlock:failBlock
              completeBlock:^(ZKDescribeSObject *result) {
      // this is always called on the main thread, can fiddle with the cache directly
      [self addDescribesToCache:@[result]];
      completeBlock(result);
    }];
}

- (void)enumerateDescribes:(NSArray *)types
                 failBlock:(ZKFailWithErrorBlock)failBlock
             describeBlock:(void(^)(ZKDescribeSObject *desc, BOOL isLast, BOOL *stop))describeBlock {

    NSMutableSet *todo = [NSMutableSet setWithArray:types];
    [todo minusSet:[NSSet setWithArray:describes.allKeys]];
    for (NSString *name in todo) {
        [self.describer prioritize:name];
    }
    void(^__block next)(int idx) = nil;
    next = ^(int idx) {
        [self describe:types[idx] failBlock:failBlock completeBlock:^(ZKDescribeSObject *result) {
            BOOL stop = NO;
            BOOL last = idx >= types.count-1;
            describeBlock(result, last, &stop);
            if ((!stop) && (!last)) {
                next(idx+1);
            } else {
                next = nil;
            }
        }];
    };
    next(0);
}

-(void)addDescribesToCache:(NSArray *)newDescribes {
    NSMutableArray *sorted = [NSMutableArray arrayWithCapacity:newDescribes.count];
    for (ZKDescribeSObject * d in newDescribes) {
        [sorted addObject:[d.fields sortedArrayUsingDescriptors:@[fieldSortOrder]]];
    }
    int i = 0;
    for (ZKDescribeSObject *d in newDescribes) {
        NSString *k = d.name.lowercaseString;
        if (self->describes[k] == nil) {
            self->describes[k] = d;
            self->sortedDescribes[k] = sorted[i];
        }
        i++;
        [outlineView reloadItem:descGlobalSobjects[k] reloadChildren:YES];
    }
    [self updateFilter];
}

-(void)stopBackgroundDescribe {
    [self.describer stop];
}

// DescriberDelegate
-(void)described:(NSArray<ZKDescribeSObject*> *)sobjects {
    [self addDescribesToCache:sobjects];
    [self.delegate described:sobjects];
}

-(void)describe:(NSString *)sobject failed:(NSError *)err {
    [self.delegate describe:sobject failed:err];
}

// for use in an outline view
- (NSInteger)outlineView:(NSOutlineView *)outlineView numberOfChildrenOfItem:(id)item {
    if (item == nil) return filteredTypes.count;
    return [self cachedDescribe:[item name]].fields.count;
}

- (BOOL)outlineView:(NSOutlineView *)outlineView isItemExpandable:(id)item  {
    return item == nil || [item isKindOfClass:[ZKDescribeGlobalSObject class]];
}

- (id)outlineView:(NSOutlineView *)outlineView child:(NSInteger)index ofItem:(id)item {
    if (item == nil) return filteredTypes[index];
    NSArray *fields = [self cachedDescribe:[item name]].fields;
    BOOL isSorted = [[NSUserDefaults standardUserDefaults] boolForKey:PREF_SORTED_FIELD_LIST];
    if (isSorted)
        fields = sortedDescribes[[item name].lowercaseString];
    return fields[index];
}

- (id)outlineView:(NSOutlineView *)outlineView objectValueForTableColumn:(NSTableColumn *)tableColumn byItem:(id)item {
    if ([tableColumn.headerCell.stringValue isEqualToString:@"SObjects"]) {
        return [item name];
    }
    return nil;
}

-(NSCell *)outlineView:(NSOutlineView *)outlineView dataCellForTableColumn:(NSTableColumn *)tableColumn item:(id)item {
    HighlightTextFieldCell *c = tableColumn.dataCell;
    c.zkImage = nil;
    c.zkStandout = NO;
    c.zkTextXOffset = 8;
    c.textColor = [NSColor textColor];
    c.font = [NSFont systemFontOfSize:12.0f];
    
    if ([item isKindOfClass:[ZKDescribeGlobalSObject class]]) {
        c.zkTextXOffset = 18;
        c.zkImage = [self iconForType:[item name]];
        if (![self hasDescribe:[item name]]) {
            c.textColor = [c.textColor colorWithAlphaComponent:0.75];
        }

    } else if ([item isKindOfClass:[ZKDescribeField class]]) {
        if ([item fieldMatchesFilter:filter]) {
            c.font = [NSFont boldSystemFontOfSize:13.0f];
            c.textColor = [[NSColor blueColor] blendedColorWithFraction:0.5 ofColor:[NSColor blackColor]];
            [c setZkStandout:YES];
        }
    }
    return c;
}

-(CGFloat)outlineView:(NSOutlineView *)ov heightOfRowByItem:(id)item {
    if ([item isKindOfClass:[ZKDescribeField class]]) {
        if ([item fieldMatchesFilter:filter]) {
            return ov.rowHeight + 4;
        }
    }
    return ov.rowHeight;
}

@end

@implementation SObjectDataSource


- (instancetype)initWithDescribe:(ZKDescribeSObject *)s {
    self = [super init];
    sobject = s;
    
    NSMutableArray *t = [NSMutableArray arrayWithObjects:@"Name", @"Label", @"PluralLabel", @"Key Prefix", @"Custom", 
                @"Createable", @"Updateable", @"Activateable", @"Deletable", @"Undeletable", 
                @"Mergeable", @"Queryable", @"Retrieveable", @"Searchable", @"Layoutable",
                @"Replicateable", @"Triggerable", @"MRU Enabled", @"Has Subtypes",
                @"Associate Entity Type", @"Associate Parent Entity",
                @"URL for Edit", @"URL for Detail", @"URL for New", nil];
    NSArray *cr = s.childRelationships;
    if (cr.count > 0) {
        NSString *sectionTitle = [NSString stringWithFormat:@"Relationships to %@", sobject.name];
        NSAttributedString *boldTitle = [[NSAttributedString alloc] initWithString:sectionTitle attributes:@{NSFontAttributeName: [NSFont boldSystemFontOfSize:11]}];
        [t addObject:boldTitle]; 
        for (ZKChildRelationship *r in cr) {
            [t addObject:[NSString stringWithFormat:@"%@.%@", r.childSObject, r.field]];
        }
    }
    titles = t;
    return self;
}


- (NSString *)description {
    return [NSString stringWithFormat:@"SObject : %@", sobject.name];
}

// for use in a table view
-(NSInteger)numberOfRowsInTableView:(NSTableView *)view {
    return titles.count;
}

-(id)tableView:(NSTableView *)view objectValueForTableColumn:(NSTableColumn *)tc row:(NSInteger)rowIdx {
    if ([tc.identifier isEqualToString:@"title"])
        return titles[rowIdx];

    switch (rowIdx) {
        case 0: return sobject.name;
        case 1: return sobject.label;
        case 2: return sobject.labelPlural;
        case 3: return sobject.keyPrefix;
        case 4: return sobject.custom ? @"Yes" : @"";
        case 5: return sobject.createable ? @"Yes" : @"";
        case 6: return sobject.updateable ? @"Yes" : @"";
        case 7: return sobject.activateable ? @"Yes" : @"";
        case 8: return sobject.deletable ? @"Yes" : @"";
        case 9: return sobject.undeletable ? @"Yes" : @"";
        case 10: return sobject.mergeable ? @"Yes" : @"";
        case 11: return sobject.queryable ? @"Yes" : @"";
        case 12: return sobject.retrieveable ? @"Yes" : @"";
        case 13: return sobject.searchable ? @"Yes" : @"";
        case 14: return sobject.layoutable ? @"Yes" : @"";
        case 15: return sobject.replicateable ? @"Yes" : @"";
        case 16: return sobject.triggerable ? @"Yes" : @"";
        case 17: return sobject.mruEnabled ? @"Yes" : @"";
        case 18: return sobject.hasSubtypes ? @"Yes" : @"";
        case 19: return sobject.associateEntityType;
        case 20: return sobject.associateParentEntity;
        case 21: return sobject.urlEdit;
        case 22: return sobject.urlDetail;
        case 23: return sobject.urlNew;
        case 24: return @""; // this is the Child Relationships title row
    };
    ZKChildRelationship *cr = sobject.childRelationships[rowIdx - 25];
    return cr.relationshipName == nil ? @"" : cr.relationshipName;
}

@end

@implementation SObjectFieldDataSource

- (instancetype)initWithDescribe:(ZKDescribeField *)f {
    self = [super init];
    field = f;
    titles = @[@"Name", @"Label", @"Type", @"Custom", @"Help Text",
                    @"Length", @"Digits", @"Scale", @"Precision", @"Byte Length",
                    @"Default Value", @"Createable", @"Updatable", @"Cascade Delete", @"Restricted Delete",
                    @"Default On Create", @"Calculated", @"AutoNumber",
                    @"Unique", @"Case Sensitive", @"Name Pointing", @"Sortable", @"Groupable", @"Aggregatable", @"Permissionable",
                    @"External Id", @"ID Lookup", @"Filterable", @"HTML Formatted", @"Name Field", @"Nillable", 
                    @"Compound FieldName", @"Name Pointing", @"Extra TypeInfo", @"Reference To", @"Relationship Name",
                    @"Dependent Picklist", @"Controller Name", @"Restricted Picklist", @"Query By Distance",
                    @"Value Formula", @"Default Formula", @"Relationship Order (CJOs)", @"Write Requires Read on Master (CJOs)", @"Display Location in Decimal"];
    return self;
}


- (NSString *)description {
    return [NSString stringWithFormat:@"Field : %@.%@", field.sobject.name, field.name];
}

// for use in a table view
- (NSInteger)numberOfRowsInTableView:(NSTableView *)view {
    return titles.count;
}

NSObject *fmtInt(NSInteger v) {
    return v == 0 ? @"": [NSNumber numberWithInteger:v];
}

- (id)tableView:(NSTableView *)view objectValueForTableColumn:(NSTableColumn *)tc row:(NSInteger)rowIdx {
    if ([tc.identifier isEqualToString:@"title"])
        return titles[rowIdx];
    
    if (field == nil) return @"";
    switch (rowIdx) {
        case 0 : return field.name;
        case 1 : return field.label;
        case 2 : return field.type;
        case 3 : return field.custom? @"Yes" : @"";
        case 4 : return field.inlineHelpText;
        case 5 : return fmtInt(field.length);
        case 6 : return fmtInt(field.digits);
        case 7 : return fmtInt(field.scale);
        case 8 : return fmtInt(field.precision);
        case 9 : return fmtInt(field.byteLength);
        case 10 : return field.defaultValueAsString;
        case 11 : return field.createable? @"Yes" : @"";
        case 12 : return field.updateable? @"Yes" : @"";
        case 13 : return field.cascadeDelete? @"Yes" : @"";
        case 14 : return field.restrictedDelete? @"Yes" : @"";
        case 15 : return field.defaultedOnCreate? @"Yes" : @"";
        case 16 : return field.calculated? @"Yes" : @"";
        case 17 : return field.autoNumber? @"Yes" : @"";
        case 18 : return field.unique? @"Yes" : @"";
        case 19 : return field.caseSensitive? @"Yes" : @"";
        case 20 : return field.namePointing? @"Yes" : @"";
        case 21 : return field.sortable? @"Yes" : @"";
        case 22 : return field.groupable? @"Yes" : @"";
        case 23 : return field.aggregatable? @"Yes" : @"";
        case 24 : return field.permissionable? @"Yes" : @"";
        case 25 : return field.externalId? @"Yes" : @"";
        case 26 : return field.idLookup? @"Yes" : @"";
        case 27 : return field.filterable? @"Yes" : @"";
        case 28 : return field.htmlFormatted? @"Yes" : @"";
        case 29 : return field.nameField? @"Yes" : @"";
        case 30 : return field.nillable? @"Yes" : @"";
        case 31 : return field.compoundFieldName;
        case 32 : return field.namePointing? @"Yes" : @"";
        case 33 : return field.extraTypeInfo;
        case 34 : return [field.referenceTo componentsJoinedByString:@", "];
        case 35 : return field.relationshipName;
        case 36 : return field.dependentPicklist? @"Yes" : @"";
        case 37 : return field.controllerName;
        case 38 : return field.restrictedPicklist? @"Yes" : @"";
        case 39 : return field.queryByDistance? @"Yes" : @"";
        case 40 : return field.calculatedFormula;
        case 41 : return field.defaultValueFormula;
        case 42 : return fmtInt(field.relationshipOrder);
        case 43 : return field.writeRequiresMasterRead? @"Yes" : @"";
        case 44 : return field.displayLocationInDecimal? @"Yes" : @"";
        default:
            NSLog(@"Unexpected rowId:%ld in SObjectFieldDataSource", (long)rowIdx);
    }
    return @"*****";
}

@end

@implementation NoSelection 

-(BOOL)tableView:(NSTableView *)aTableView shouldSelectRow:(int)rowIndex {
    return NO;
}

@end

