//
//  MonteCarloTreeSearch.swift
//  iReversi
//
//  Created by Julia Szczuczko on 21.08.2024.
//

import Foundation

final class MonteCarloTreeSearch {
    private var root: MCTSNode
    private let opponentColor: ReversiBoard.Color
    private let dispatchGroup: DispatchGroup = DispatchGroup()
    
    init(startingGameState: ReversiGame, opponentColor: ReversiBoard.Color) {
        self.root = MCTSNode(gameState: startingGameState) // build a container node
        self.opponentColor = opponentColor
    }
    
    func iterateSearch() {
        if root.hasUnsimulatedPlays() == false {
            return
        }
        
        let pickedNode = MonteCarloTreeSearch.tree_policy(root) // pick child state to simulate on
        let concurrency = ProcessInfo.processInfo.activeProcessorCount
        var mutex = os_unfair_lock()
        
        var results = Array<Int>(repeating: 0, count: concurrency)
        for i in 0..<concurrency {
            DispatchQueue.global(qos: DispatchQoS.QoSClass.userInitiated).async(group: dispatchGroup) {
                let result = MonteCarloTreeSearch.simulate(pickedNode.gameState, colorToOptimize: self.opponentColor) // run one sim from this state, return win or lose
                
                os_unfair_lock_lock(&mutex)
                results[i] = result
                os_unfair_lock_unlock(&mutex)
            }
        }
        _ = dispatchGroup.wait(timeout: DispatchTime.distantFuture)
        
        for result in results {
            MonteCarloTreeSearch.back_prop(fromNode: pickedNode, delta: result) // back propagate the result up the tree
        }
    }
    
    func hasUnsimulatedPlays() -> Bool {
        return root.hasUnsimulatedPlays()
    }
    
    func updateStartingState(_ startingGameState: ReversiGame) {
        let newRoot = MonteCarloTreeSearch.findMatchingNode(startingGameState, fromNode: root)
        if newRoot != nil && newRoot!.plays > 0 {
            print("    Found root from previous run \(newRoot!)")
            print("    Number of old simulations: \(newRoot!.plays), reuse: \(Int(Double(newRoot!.plays) / Double(root.plays) * 100))%")
            root = newRoot!
            root.parent = nil
            root.move = ReversiMove(x: -1, y: -1) // This move can't ever be taken, it's the current state.
        } else {
            root = MCTSNode(gameState: startingGameState) // build a container node
        }
    }
    
    func bestAction() -> ReversiMove {
        return MonteCarloTreeSearch.best_move(root)
    }
    
    func results() -> (bestMove: ReversiMove, simulations: Int, confidence: Double, moves: [MCTSNode]) {
        let bestChild = MonteCarloTreeSearch.best_move_child(root)
        let confidence: Double
        
        if bestChild.plays == 0 {
            confidence = 100
        } else {
            confidence = Double(bestChild.wins) / Double(bestChild.plays)
        }
        
        return (bestMove: bestChild.move, simulations:root.plays, confidence: confidence, root.children)
    }
}

private extension MonteCarloTreeSearch {
    static func findMatchingNode(_ gameState: ReversiGame, fromNode node: MCTSNode) -> MCTSNode? {
        if node.gameState == gameState {
            return node
        }
        
        if node.gameState.board.numberOfPieces > gameState.board.numberOfPieces {
            return nil
        }
        
        for child in node.children {
            let matchingNode = findMatchingNode(gameState, fromNode: child)
            
            if matchingNode != nil {
                return matchingNode
            }
        }
        
        return nil
    }
    
    static func simulate(_ initialGameState: ReversiGame, colorToOptimize playerColor: ReversiBoard.Color) -> Int {
        var gameState = initialGameState
        
        while true {
            switch gameState.state {
            case .won(let color):
                return color == playerColor ? 1 : 0
            case .tie:
                return 0
            case .turn(let color):
                let availableMoves = gameState.allMoves(color)
                
                gameState.makeMove(availableMoves.randomElement()!, for: color)
            }
        }
    }
    
    static func tree_policy(_ root: MCTSNode) -> MCTSNode {
        // Given a root node, determine which child to visit using Upper Confidence Bound.
        var curNode = root
        while true {
            switch curNode.gameState.state {
            case .won(_):
                return curNode
            case .tie:
                return curNode
            case .turn(let color):
                if curNode.allMovesExpanded == false {
                    //assert(curNode.allMovesExpanded == false)
                    let legal_moves = curNode.gameState.allMoves(color)
                    // children are not fully expanded, so expand one
                    let unexpanded = legal_moves.filter({ (move: ReversiMove) -> Bool in
                        return !curNode.hasVisitedMove(move)
                    })
                    assert(unexpanded.count > 0)
                    let move = unexpanded.randomElement()!
                    let state = ReversiGame.makeMove(startingState: curNode.gameState, move: move, forColor: color)
                    let n = MCTSNode(gameState: state, move: move)
                    curNode.addChild(n)
                    
                    if curNode.children.count == legal_moves.count {
                        curNode.allMovesExpanded = true
                    }
                    
                    return n
                } else {
                    //assert(curNode.allMovesExpanded)
                    // Every possible next state has been expanded, so pick one
                    curNode = best_child(curNode)
                }
            }
        }
        //return curNode
    }
    
    static func best_child(_ node: MCTSNode) -> MCTSNode{
        let C: Float = 2 * sqrt(2)  // 'exploration' value, higher is more exploration oriented (in contrast to exploitation orientated)
        var values = [MCTSNode: Float]()
        for child in node.children {
            let wins = child.wins
            let plays = child.plays
            let parent_plays = node.plays
            assert(parent_plays > 0)
            
            values[child] = (Float(wins) / Float(plays)) + C * sqrt(log(Float(parent_plays)) / Float(plays))
        }
        
        let best_choice = values.max { (left: (MCTSNode, Float), right: (MCTSNode, Float)) -> Bool in
            let (_, leftValue) = left
            let (_, rightValue) = right
            return leftValue < rightValue // "left.1 < right.1" for short
            }!.0
        
        return best_choice
    }
    
    static func back_prop(fromNode startNode: MCTSNode, delta: Int) {
        var node = startNode
        // Given a node and a delta value for wins, propagate that information up the tree to the root.
        while node.parent != nil {
            node.plays += 1
            node.wins += delta
            node = node.parent!
        }
        
        // update root node of entire tree
        node.plays += 1
        node.wins += delta
    }
    
    static func best_move_child(_ node: MCTSNode) -> MCTSNode {
        // Returns the best action from this game state node. In Monte Carlo Tree Search we pick the one that was visited the most. We can break ties by picking the state that won the most.
        var most_plays = Int.min
        var best_wins = Int.min
        var best_children = [MCTSNode]()
        
        for child in node.children {
            let wins = child.wins
            let plays = child.plays
            
            if plays > most_plays {
                most_plays = plays
                best_children = [child]
                best_wins = wins
            } else if plays == most_plays {
                // break ties with wins
                if wins > best_wins {
                    best_wins = wins
                    best_children = [child]
                } else if wins == best_wins {
                    best_children.append(child)
                }
            }
        }
        return best_children.randomElement()!
    }
    
    static func best_move(_ node: MCTSNode) -> ReversiMove {
        return best_move_child(node).move
    }
}
