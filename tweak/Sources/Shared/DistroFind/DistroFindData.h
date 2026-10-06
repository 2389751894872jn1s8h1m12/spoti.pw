// DistroFind's built-in distributor database and sub-distributor heuristics.
// Ported from the Spicetify DistroFind extension; kept separate from the network engine so
// metadata lookup and UI do not carry a giant literal table in their source.
#import <Foundation/Foundation.h>

NSString *SGDistroNameForUUID(NSString *uuid);
NSArray<NSDictionary *> *SGDistroLikelyRulesForUUID(NSString *uuid);
