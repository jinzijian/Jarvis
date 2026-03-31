import Foundation

struct LoginRequest: Encodable {
    let email: String
    let password: String
}

struct RefreshRequest: Encodable {
    let refresh_token: String
}

struct AuthResponse: Decodable {
    let access_token: String
    let refresh_token: String
    let token_type: String
    let expires_in: Int
    let user: UserResponse
}

struct UserResponse: Decodable {
    let id: String
    let email: String
    let created_at: String?
}
