import Foundation

/// ISO 18245 Merchant Category Code (MCC) directory mapping network codes to `RewardCategory`
/// and human-readable labels. Issuers determine bonus earn rates by MCC, so this lookup takes
/// priority whenever Plaid supplies `merchant_category_code`.
enum MCCDirectory {
    /// Parses a 4-digit MCC string (trimming whitespace) into an integer code.
    static func parse(_ raw: String?) -> Int? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              let code = Int(trimmed),
              (1...9999).contains(code) else { return nil }
        return code
    }

    static func category(forCode raw: String?) -> RewardCategory? {
        parse(raw).flatMap(category(for:))
    }

    /// Maps an ISO 18245 MCC integer to the matching `RewardCategory`, or `nil` if unmapped.
    static func category(for mcc: Int) -> RewardCategory? {
        switch mcc {
        // Travel: airlines, hotels, car rentals, cruises, agencies
        case 3000...3350, 4511:
            return .flights
        case 3351...3500, 7512, 7513, 7519:
            return .carRental
        case 3501...3999, 7011:
            return .hotels
        case 4411, 4457, 4468, 4582, 4722, 4723, 4789, 5962, 7012, 7032, 7033:
            return .travel

        // Local transit, tolls, parking
        case 4011, 4111, 4112, 4121, 4131, 4784, 7523:
            return .transit

        // Dining & groceries
        case 5811, 5812, 5813, 5814:
            return .dining
        case 5411, 5422, 5441, 5451, 5462, 5499:
            return .groceries

        // Gas & EV charging
        case 5541, 5542, 5983:
            return .gas
        case 5552:
            return .evCharging

        // Drugstores & pharmacies
        case 5912:
            return .drugstore

        // Streaming & digital media
        case 4899, 5815, 5816, 5817, 5818:
            return .streaming

        // Entertainment & recreation
        case 7829, 7832, 7841, 7911, 7922, 7929, 7932, 7933, 7941, 7991, 7992, 7993, 7994, 7996, 7998, 7999:
            return .entertainment

        // Wholesale clubs
        case 5300:
            return .wholesale

        // Home improvement, hardware & furnishings
        case 5200, 5211, 5231, 5251, 5261, 5712, 5713, 5714, 5718, 5719, 5722:
            return .homeImprovement

        // Retail, apparel, electronics & general shopping
        case 5045, 5309, 5310, 5311, 5331, 5399,
             5611, 5621, 5631, 5641, 5651, 5655, 5661, 5681, 5691, 5699,
             5732, 5733, 5734, 5735,
             5931, 5941, 5942, 5944, 5945, 5946, 5947, 5948, 5949,
             5964, 5965, 5969, 5970, 5971, 5977, 5992, 5994, 5995, 5999:
            return .shopping

        // Telecom & utilities
        case 4812, 4814, 4816, 4821:
            return .telecom
        case 4900:
            return .utilities

        // Fitness & wellness
        case 7298, 7997:
            return .fitness

        // Healthcare & medical services
        case 4119, 5975, 5976, 8011, 8021, 8031, 8041, 8042, 8043, 8049, 8050, 8062, 8071, 8099:
            return .healthcare

        // Automotive dealers, parts & service
        case 5511, 5521, 5531, 5532, 5533, 7531, 7534, 7535, 7538, 7542, 7549:
            return .auto

        // Office supplies, shipping & business services
        case 4214, 4215, 5021, 5044, 5111, 5943, 7311, 7333, 7338, 7372, 9402:
            return .office

        // Insurance
        case 5960, 6300, 6381, 6399:
            return .insurance

        default:
            return nil
        }
    }

    /// Formats a raw MCC string for display in transaction details (e.g. `"5411 · Grocery Stores & Supermarkets"`).
    static func label(for raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let code = parse(trimmed), let name = description(for: code) else { return trimmed }
        return "\(String(format: "%04d", code)) · \(name)"
    }

    /// Concise ISO 18245 merchant category description for display.
    static func description(for mcc: Int) -> String? {
        switch mcc {
        case 3000...3350, 4511: "Airlines & Air Carriers"
        case 3351...3500, 7512: "Car Rental Agencies"
        case 3501...3999, 7011: "Hotels, Motels & Resorts"
        case 4011: "Railroads"
        case 4111: "Commuter Passenger Transport"
        case 4112: "Passenger Railways"
        case 4119: "Ambulance Services"
        case 4121: "Taxicabs & Rideshare"
        case 4131: "Bus Lines"
        case 4214: "Moving & Storage"
        case 4215: "Courier & Shipping Services"
        case 4411: "Cruise Lines"
        case 4457, 4468: "Boat Rentals & Marinas"
        case 4582: "Airport Terminals"
        case 4722, 4723: "Travel Agencies & Tour Operators"
        case 4784: "Tolls & Bridge Fees"
        case 4789: "Transportation Services"
        case 4812: "Telecom Equipment"
        case 4814: "Telecommunication Services"
        case 4816: "Internet & Network Services"
        case 4821: "Telegraph Services"
        case 4899: "Cable, Satellite & Streaming"
        case 4900: "Electric, Gas, Water & Utilities"
        case 5021, 5044, 5111: "Commercial Office Supplies"
        case 5045: "Computers & Peripherals"
        case 5200: "Home Supply Warehouse Stores"
        case 5211: "Lumber & Building Materials"
        case 5231: "Paint & Glass Stores"
        case 5251: "Hardware Stores"
        case 5261: "Lawn & Garden Supply"
        case 5300: "Wholesale Clubs"
        case 5309: "Duty Free Stores"
        case 5310: "Discount Stores"
        case 5311: "Department Stores"
        case 5331: "Variety Stores"
        case 5399: "General Merchandise"
        case 5411: "Grocery Stores & Supermarkets"
        case 5422: "Freezer & Meat Provisioners"
        case 5441: "Candy & Confectionery Stores"
        case 5451: "Dairy Products Stores"
        case 5462: "Bakeries"
        case 5499: "Specialty Food & Convenience Stores"
        case 5511, 5521: "Auto Dealers"
        case 5531, 5532, 5533: "Auto Parts & Tires"
        case 5541: "Service Stations"
        case 5542: "Automated Fuel Dispensers"
        case 5552: "Electric Vehicle Charging"
        case 5611, 5621, 5631, 5641, 5651, 5655, 5681, 5691, 5699: "Clothing & Apparel Stores"
        case 5661: "Shoe Stores"
        case 5712: "Furniture & Home Furnishings"
        case 5713, 5714, 5718, 5719: "Home Furnishings"
        case 5722: "Household Appliance Stores"
        case 5732: "Electronics Stores"
        case 5733: "Music Stores"
        case 5734: "Computer Software Stores"
        case 5735: "Record Stores"
        case 5811: "Caterers"
        case 5812: "Eating Places & Restaurants"
        case 5813: "Bars, Taverns & Lounges"
        case 5814: "Fast Food Restaurants"
        case 5815: "Digital Media, Books & Music"
        case 5816: "Digital Games"
        case 5817: "Digital Applications"
        case 5818: "Large Digital Goods Merchants"
        case 5912: "Drug Stores & Pharmacies"
        case 5931: "Secondhand Stores"
        case 5941: "Sporting Goods Stores"
        case 5942: "Book Stores"
        case 5943: "Stationery & Office Supply Stores"
        case 5944: "Jewelry Stores"
        case 5945: "Hobby, Toy & Game Shops"
        case 5946: "Camera & Photo Supply"
        case 5947: "Gift & Card Shops"
        case 5948: "Luggage & Leather Goods"
        case 5949: "Sewing & Fabric Stores"
        case 5960, 6300, 6381, 6399: "Insurance"
        case 5962: "Travel-Related Direct Marketing"
        case 5964, 5965, 5969: "Catalog & Online Retail"
        case 5970, 5971: "Art & Craft Stores"
        case 5975, 5976: "Medical Equipment & Aids"
        case 5977: "Cosmetic Stores"
        case 5983: "Fuel Dealers"
        case 5992: "Florists"
        case 5994: "Newsstands"
        case 5995: "Pet Shops & Supplies"
        case 5999: "Miscellaneous Retail"
        case 7012: "Timeshares"
        case 7032, 7033: "Camps & Campgrounds"
        case 7298: "Health & Beauty Spas"
        case 7311: "Advertising Services"
        case 7333, 7338: "Design & Copy Services"
        case 7372: "Software & Cloud Services"
        case 7513, 7519: "Truck & RV Rentals"
        case 7523: "Parking Lots & Garages"
        case 7531, 7534, 7535, 7538: "Automotive Repair & Service"
        case 7542: "Car Washes"
        case 7549: "Towing Services"
        case 7829, 7832, 7841: "Movie Theaters & Cinema"
        case 7911: "Dance Studios"
        case 7922: "Theatrical Ticket Agencies"
        case 7929: "Bands & Live Entertainment"
        case 7932, 7933: "Bowling & Billiards"
        case 7941: "Commercial & Pro Sports"
        case 7991: "Tourist Attractions & Exhibits"
        case 7992: "Public Golf Courses"
        case 7993, 7994: "Amusement & Arcades"
        case 7996: "Amusement Parks & Circuses"
        case 7997: "Health & Fitness Clubs"
        case 7998: "Aquariums & Zoos"
        case 7999: "Recreation Services"
        case 8011: "Doctors & Physicians"
        case 8021: "Dentists & Orthodontists"
        case 8031: "Osteopaths"
        case 8041: "Chiropractors"
        case 8042, 8043: "Optometrists & Eyeglasses"
        case 8049: "Podiatrists"
        case 8050: "Nursing & Care Facilities"
        case 8062: "Hospitals"
        case 8071: "Medical & Dental Labs"
        case 8099: "Medical Services"
        case 9402: "Postal Services"
        default: nil
        }
    }
}
