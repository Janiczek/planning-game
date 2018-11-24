module Data exposing (User, setName, userDecoder)

import Http
import Json.Decode as Decode exposing (Decoder)
import Json.Decode.Extra as Decode
import Json.Encode as Encode


type alias User =
    { name : String
    , isOnline : Bool
    }


userDecoder : Decoder User
userDecoder =
    Decode.succeed User
        |> Decode.andMap (Decode.field "name" Decode.string)
        |> Decode.andMap (Decode.field "isOnline" Decode.bool)


setName : (Result Http.Error String -> msg) -> String -> Cmd msg
setName msg name =
    Http.post
        { url = "http://localhost:3000/join"
        , body = Http.jsonBody <| Encode.object [ ( "name", Encode.string name ) ]
        , expect = Http.expectJson msg Decode.string
        }
