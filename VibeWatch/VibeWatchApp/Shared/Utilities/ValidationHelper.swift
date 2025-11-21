import Foundation

struct ValidationHelper {
    
    // MARK: - Email Validation
    
    static func isValidEmail(_ email: String) -> Bool {
        // Regex for valid email with real domain
        let emailRegex = "^[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,64}$"
        let emailPredicate = NSPredicate(format: "SELF MATCHES %@", emailRegex)
        
        guard emailPredicate.evaluate(with: email) else {
            return false
        }
        
        // Additional check for common test domains
        let invalidDomains = ["test.com", "example.com", "test.test", "test.test.com"]
        let domain = email.components(separatedBy: "@").last?.lowercased() ?? ""
        
        return !invalidDomains.contains(domain)
    }
    
    // MARK: - Password Validation
    
    static func isValidPassword(_ password: String) -> Bool {
        // Minimum 8 characters
        guard password.count >= 8 else {
            return false
        }
        
        // Must contain at least one uppercase letter
        let uppercaseRegex = ".*[A-Z]+.*"
        let uppercasePredicate = NSPredicate(format: "SELF MATCHES %@", uppercaseRegex)
        guard uppercasePredicate.evaluate(with: password) else {
            return false
        }
        
        // Must contain at least one lowercase letter
        let lowercaseRegex = ".*[a-z]+.*"
        let lowercasePredicate = NSPredicate(format: "SELF MATCHES %@", lowercaseRegex)
        guard lowercasePredicate.evaluate(with: password) else {
            return false
        }
        
        // Must contain at least one number
        let numberRegex = ".*[0-9]+.*"
        let numberPredicate = NSPredicate(format: "SELF MATCHES %@", numberRegex)
        guard numberPredicate.evaluate(with: password) else {
            return false
        }
        
        return true
    }
    
    static func getPasswordRequirements() -> [String] {
        return [
            "At least 8 characters",
            "One uppercase letter",
            "One lowercase letter",
            "One number"
        ]
    }
}
